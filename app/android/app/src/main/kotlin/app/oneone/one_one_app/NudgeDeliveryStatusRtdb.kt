package app.oneone.one_one_app

import android.content.Context
import android.os.PowerManager
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Conclusive nudge delivery status for the sender — written **directly to
 * RTDB by the receiving device**. No Render/backend hop.
 *
 * Path: `userNudgeDeliveries/{senderUserId}/{eventId}/{recipientUserId}`
 * Sender listens / gets this path via the Firebase SDK.
 *
 * Writes are persisted locally first and retried until RTDB confirms them.
 * Cold FCM starts often have Auth/RTDB not ready at the moment audio begins;
 * skipping the write left the sender with a false "did not reach" timeout
 * even though playback succeeded.
 */
object NudgeDeliveryStatusRtdb {
    private const val prefsName = "one_one_nudge_delivery_acks"
    private const val pendingKey = "pending_acks_json"
    private const val wakeLockTag = "oneone:nudge-delivery-ack"
    private const val wakeLockTimeoutMs = 25_000L

    private val retryExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "oneone-nudge-ack").apply { isDaemon = true }
        }
    private val inFlight = ConcurrentHashMap.newKeySet<String>()
    private val authListenerRegistered = AtomicBoolean(false)
    @Volatile private var ackWakeLock: PowerManager.WakeLock? = null

    private val database: FirebaseDatabase by lazy {
        FirebaseDatabase.getInstance(FirebaseApp.getInstance(), mediaVolumeDatabaseUrl)
    }

    fun enablePersistence() {
        try {
            database.setPersistenceEnabled(true)
        } catch (_: Exception) {
            // Already enabled, or invoked after the first use in this process.
        }
    }

    /**
     * Open the RTDB connection and restore Auth *before* playback finishes so
     * the played ACK is not the first thing that touches Firebase.
     */
    fun warm(context: Context? = null) {
        context?.let { DeviceLog.init(it) }
        ensureAuthListener()
        try {
            database.goOnline()
            FirebaseAuth.getInstance().currentUser
        } catch (error: Exception) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB warm failed detail=${error.message ?: "-"}",
            )
        }
        flushPending(context ?: DeviceLog.appContext)
    }

    /**
     * Persist played/failed for this device. Safe to call from any thread;
     * Firebase SDK handles the write asynchronously. Never skips just because
     * Auth has not restored yet — the ACK is queued and flushed when it can.
     */
    fun write(
        senderUserId: String?,
        eventId: String?,
        groupId: String?,
        kind: String?,
        status: String,
        reason: String? = null,
        attention: String? = null,
        recipientName: String? = null,
        recipientUserId: String? = null,
    ) {
        val sender = senderUserId?.trim().orEmpty()
        val event = eventId?.trim().orEmpty()
        val group = groupId?.trim().orEmpty()
        if (sender.isEmpty() || event.isEmpty()) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write skipped: missing sender/event " +
                    "status=$status eventId=${event.ifEmpty { "-" }} " +
                    "senderUserId=${sender.ifEmpty { "-" }}",
                groupId = group.ifEmpty { null },
            )
            return
        }
        if (!NudgeDeliveryAckPolicy.shouldOverwrite(null, status)) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write skipped: invalid status=$status eventId=$event",
                groupId = group.ifEmpty { null },
            )
            return
        }

        val authUid = FirebaseAuth.getInstance().currentUser?.uid?.trim()
        val resolvedRecipient = NudgeDeliveryAckPolicy.resolveRecipientUserId(
            authUid = authUid,
            deviceLogUid = DeviceLog.currentUserId(),
            payloadUid = recipientUserId,
        )
        val name = recipientName?.trim()?.takeIf { it.isNotEmpty() }
            ?: FirebaseAuth.getInstance().currentUser?.displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: "friend"

        val normalizedKind = when (kind?.trim()) {
            VoiceNudgeContract.kindRing, "ring_nudge" -> "ring_nudge"
            VoiceNudgeContract.kindPush, "nudge" -> "nudge"
            else -> "voice_nudge"
        }

        val payload = JSONObject().apply {
            put("eventId", event)
            put("groupId", group)
            put("kind", normalizedKind)
            put("senderUserId", sender)
            put("recipientUserId", resolvedRecipient ?: JSONObject.NULL)
            put("recipientName", name)
            put("status", status)
            put("recordedAt", System.currentTimeMillis() / 1000L)
            put("queuedAt", System.currentTimeMillis())
            if (!reason.isNullOrBlank()) put("reason", reason)
            if (!attention.isNullOrBlank()) put("attention", attention)
        }

        val context = DeviceLog.appContext
        if (context != null) persistPending(context, payload)

        if (resolvedRecipient.isNullOrBlank()) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write queued: no recipient uid yet eventId=$event " +
                    "status=$status authReady=${!authUid.isNullOrBlank()}",
                groupId = group.ifEmpty { null },
            )
            ensureAuthListener()
            scheduleRetry(event, attempt = 1)
            return
        }

        DeviceLog.info(
            "NudgeService",
            "Delivery RTDB write start status=$status eventId=$event " +
                "senderUserId=$sender recipientUserId=$resolvedRecipient " +
                "reason=${reason ?: "-"} attention=${attention ?: "-"} " +
                "authReady=${NudgeDeliveryAckPolicy.canAttemptWrite(authUid, resolvedRecipient)}",
            groupId = group.ifEmpty { null },
        )
        attemptWrite(payload, attempt = 0)
    }

    fun flushPending(context: Context? = DeviceLog.appContext) {
        val app = context ?: return
        DeviceLog.init(app)
        ensureAuthListener()
        val pending = loadPending(app)
        if (pending.length() == 0) return
        val keys = buildList {
            val iterator = pending.keys()
            while (iterator.hasNext()) add(iterator.next().toString())
        }
        DeviceLog.info(
            "NudgeService",
            "Delivery RTDB flush pending count=${keys.size}",
        )
        for (eventId in keys) {
            val payload = pending.optJSONObject(eventId) ?: continue
            attemptWrite(payload, attempt = 0)
        }
    }

    private fun attemptWrite(payload: JSONObject, attempt: Int) {
        val event = payload.optString("eventId")
        val sender = payload.optString("senderUserId")
        val group = payload.optString("groupId")
        val status = payload.optString("status")
        if (event.isBlank() || sender.isBlank()) return

        val queuedAt = payload.optLong("queuedAt", 0L)
        if (!NudgeDeliveryAckPolicy.isPendingAckFresh(queuedAt, System.currentTimeMillis())) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write dropped: stale pending eventId=$event",
                groupId = group.ifEmpty { null },
            )
            DeviceLog.appContext?.let { removePending(it, event) }
            return
        }

        val authUid = FirebaseAuth.getInstance().currentUser?.uid?.trim()
        val resolvedRecipient = NudgeDeliveryAckPolicy.resolveRecipientUserId(
            authUid = authUid,
            deviceLogUid = DeviceLog.currentUserId(),
            payloadUid = payload.optString("recipientUserId").takeIf {
                it.isNotBlank() && it != "null"
            },
        )
        if (resolvedRecipient != null && payload.optString("recipientUserId") != resolvedRecipient) {
            payload.put("recipientUserId", resolvedRecipient)
            DeviceLog.appContext?.let { persistPending(it, payload) }
        }

        if (!NudgeDeliveryAckPolicy.canAttemptWrite(authUid, resolvedRecipient)) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write waiting for auth eventId=$event " +
                    "attempt=$attempt authUid=${authUid ?: "-"} " +
                    "recipientUserId=${resolvedRecipient ?: "-"}",
                groupId = group.ifEmpty { null },
            )
            ensureAuthListener()
            scheduleRetry(event, attempt + 1, payload)
            return
        }

        if (!inFlight.add(event)) {
            return
        }
        holdAckWakeLock()

        val path = "userNudgeDeliveries/$sender/$event/$resolvedRecipient"
        val record = mutableMapOf<String, Any>(
            "eventId" to event,
            "groupId" to group,
            "kind" to payload.optString("kind", "voice_nudge"),
            "senderUserId" to sender,
            "recipientUserId" to resolvedRecipient,
            "recipientName" to payload.optString("recipientName", "friend"),
            "status" to status,
            "recordedAt" to payload.optLong("recordedAt", System.currentTimeMillis() / 1000L),
        )
        payload.optString("reason").takeIf { it.isNotBlank() && it != "null" }
            ?.let { record["reason"] = it }
        payload.optString("attention").takeIf { it.isNotBlank() && it != "null" }
            ?.let { record["attention"] = it }

        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-RTDB] Writing delivery status=$status path=$path attempt=$attempt",
        )

        try {
            database.goOnline()
            database.reference.child(path).updateChildren(record)
                .addOnSuccessListener {
                    inFlight.remove(event)
                    DeviceLog.appContext?.let { removePending(it, event) }
                    DeviceLog.info(
                        "NudgeService",
                        "Delivery RTDB write ok status=$status eventId=$event " +
                            "recipientUserId=$resolvedRecipient attempt=$attempt",
                        groupId = group.ifEmpty { null },
                    )
                    releaseAckWakeLockIfIdle()
                }
                .addOnFailureListener { error ->
                    inFlight.remove(event)
                    Log.w(
                        VoiceNudgeDiagnostics.tag,
                        "[NUDGE-RTDB] Write failed status=$status eventId=$event: ${error.message}",
                    )
                    DeviceLog.warn(
                        "NudgeService",
                        "Delivery RTDB write failed status=$status eventId=$event " +
                            "attempt=$attempt detail=${error.message ?: "-"}",
                        groupId = group.ifEmpty { null },
                    )
                    DeviceLog.appContext?.let { persistPending(it, payload) }
                    scheduleRetry(event, attempt + 1, payload)
                    releaseAckWakeLockIfIdle()
                }
        } catch (error: Exception) {
            inFlight.remove(event)
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write threw eventId=$event attempt=$attempt " +
                    "detail=${error.message ?: "-"}",
                groupId = group.ifEmpty { null },
            )
            DeviceLog.appContext?.let { persistPending(it, payload) }
            scheduleRetry(event, attempt + 1, payload)
            releaseAckWakeLockIfIdle()
        }
    }

    private fun scheduleRetry(eventId: String, attempt: Int, payload: JSONObject? = null) {
        if (attempt >= NudgeDeliveryAckPolicy.maxAttempts) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery RTDB write gave up eventId=$eventId attempts=$attempt",
            )
            releaseAckWakeLockIfIdle()
            return
        }
        val delay = NudgeDeliveryAckPolicy.retryDelayMs(attempt)
        retryExecutor.schedule(
            {
                val next = payload
                    ?: DeviceLog.appContext?.let { loadPending(it).optJSONObject(eventId) }
                if (next != null) attemptWrite(next, attempt)
            },
            delay,
            TimeUnit.MILLISECONDS,
        )
    }

    private fun ensureAuthListener() {
        if (!authListenerRegistered.compareAndSet(false, true)) return
        FirebaseAuth.getInstance().addAuthStateListener { auth ->
            if (auth.currentUser != null) {
                flushPending(DeviceLog.appContext)
            }
        }
    }

    private fun persistPending(context: Context, payload: JSONObject) {
        val eventId = payload.optString("eventId")
        if (eventId.isBlank()) return
        synchronized(this) {
            val root = loadPending(context)
            val existing = root.optJSONObject(eventId)
            val existingStatus = existing?.optString("status")
            val incomingStatus = payload.optString("status")
            if (!NudgeDeliveryAckPolicy.shouldOverwrite(existingStatus, incomingStatus)) {
                return
            }
            root.put(eventId, payload)
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .edit()
                .putString(pendingKey, root.toString())
                .commit()
        }
    }

    private fun removePending(context: Context, eventId: String) {
        synchronized(this) {
            val root = loadPending(context)
            if (!root.has(eventId)) return
            root.remove(eventId)
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .edit()
                .putString(pendingKey, root.toString())
                .commit()
        }
    }

    private fun loadPending(context: Context): JSONObject {
        val raw = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .getString(pendingKey, "{}")
            .orEmpty()
            .ifBlank { "{}" }
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun holdAckWakeLock() {
        val context = DeviceLog.appContext ?: return
        val existing = ackWakeLock
        if (existing?.isHeld == true) return
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, wakeLockTag)
            lock.setReferenceCounted(false)
            lock.acquire(wakeLockTimeoutMs)
            ackWakeLock = lock
        } catch (error: Exception) {
            DeviceLog.warn(
                "NudgeService",
                "Delivery ACK wake lock failed detail=${error.message ?: "-"}",
            )
        }
    }

    private fun releaseAckWakeLockIfIdle() {
        if (inFlight.isNotEmpty()) return
        try {
            ackWakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        ackWakeLock = null
    }
}
