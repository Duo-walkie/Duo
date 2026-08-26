package app.oneone.one_one_app

import android.app.NotificationManager
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.google.firebase.auth.FirebaseAuth
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

data class PendingNudgeAction(
    val action: String,
    val eventId: String,
    val groupId: String,
    val senderUserId: String? = null,
) {
    fun toMap(): Map<String, String> = buildMap {
        put("action", action)
        put("eventId", eventId)
        put("groupId", groupId)
        if (!senderUserId.isNullOrBlank()) put("senderUserId", senderUserId)
    }
}

object NudgeActionStore {
    private const val preferencesName = "one_one_nudge_actions"
    private const val actionKey = "action"
    private const val eventIdKey = "event_id"
    private const val groupIdKey = "group_id"
    private const val lastEventIdKey = "last_processed_event_id"
    private const val senderUserIdKey = "sender_user_id"

    fun save(context: Context, action: PendingNudgeAction) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(actionKey, action.action)
            .putString(eventIdKey, action.eventId)
            .putString(groupIdKey, action.groupId)
            .putString(senderUserIdKey, action.senderUserId)
            .apply()
    }

    fun take(context: Context): PendingNudgeAction? {
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        val action = preferences.getString(actionKey, null) ?: return null
        val eventId = preferences.getString(eventIdKey, null) ?: return null
        val groupId = preferences.getString(groupIdKey, null) ?: return null
        val senderUserId = preferences.getString(senderUserIdKey, null)
        val lastProcessed = preferences.getString(lastEventIdKey, null)
        // Drop the pending payload but remember the event so a sticky launch
        // intent cannot re-queue the same Accept/Connect after process death.
        preferences.edit()
            .remove(actionKey)
            .remove(eventIdKey)
            .remove(groupIdKey)
            .remove(senderUserIdKey)
            .putString(lastEventIdKey, eventId)
            .apply()
        if (eventId == lastProcessed) return null
        return PendingNudgeAction(action, eventId, groupId, senderUserId)
    }
}

object NudgeActionDispatcher {
    @Volatile
    private var channel: MethodChannel? = null

    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    fun detach(methodChannel: MethodChannel) {
        if (channel === methodChannel) channel = null
    }

    /** True when the Flutter engine (MainActivity) is attached in this process. */
    fun isAttached(): Boolean = channel != null

    fun signal() {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onNudgeActionAvailable", null)
        }
    }

    fun signalRegistrationRenewed() {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onFcmRegistrationRenewed", null)
        }
    }
}

/**
 * Bridges real-time nudge delivery confirmation (#5) straight to Flutter
 * while the sender's send-nudge bottom sheet is open. Only fires when the
 * app is in the foreground and Flutter is attached — if the sender has
 * backgrounded the app or closed the sheet, the result is simply not shown
 * live (the outcome is still logged server-side either way).
 */
object NudgeDeliveryResultDispatcher {
    @Volatile
    private var channel: MethodChannel? = null

    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    fun detach(methodChannel: MethodChannel) {
        if (channel === methodChannel) channel = null
    }

    fun signal(result: Map<String, String?>) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onNudgeDeliveryResult", result)
        }
    }
}

/**
 * Forwards accept/decline/snooze responses to Flutter so the sender can show
 * profile signifiers (and connect on accept) while the app is alive.
 */
object NudgeResponseDispatcher {
    @Volatile
    private var channel: MethodChannel? = null

    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    fun detach(methodChannel: MethodChannel) {
        if (channel === methodChannel) channel = null
    }

    fun signal(result: Map<String, String?>) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onNudgeResponse", result)
        }
    }
}

/**
 * Signals Flutter that a nudge has *arrived* on this device (FCM received and
 * native playback is starting), before the user has tapped accept. This lets
 * the app prefetch/warm the LiveKit connection while the user is still
 * deciding, so the accept -> connected latency is much lower. Only fires when
 * the Flutter engine is attached; a killed app simply falls back to a normal
 * cold connect.
 */
object NudgeReceivedDispatcher {
    @Volatile
    private var channel: MethodChannel? = null

    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    fun detach(methodChannel: MethodChannel) {
        if (channel === methodChannel) channel = null
    }

    fun signal(groupId: String) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onNudgeReceived", groupId)
        }
    }
}

/**
 * On-device cache of incoming nudges (FCM arrivals + notification responses)
 * so Flutter can hydrate Case 2/3 without waiting on RTDB, and so a
 * notification Decline is not re-prompted when the app later opens.
 */
object IncomingNudgeStore {
    private const val preferencesName = "one_one_incoming_nudges"
    private const val payloadKey = "payload_json"
    private const val expiryMs = 10L * 60L * 1000L
    private const val statusRetentionMs = 24L * 60L * 60L * 1000L

    fun upsert(
        context: Context,
        eventId: String,
        groupId: String,
        senderUserId: String?,
        senderName: String?,
        arrivedAtMs: Long = System.currentTimeMillis(),
        responseUrl: String? = null,
        kind: String? = null,
    ) {
        if (eventId.isBlank() || groupId.isBlank()) return
        val records = readAll(context)
        val existing = records.optJSONObject(eventId)
        val record = existing ?: org.json.JSONObject()
        record.put("eventId", eventId)
        record.put("groupId", groupId)
        if (!senderUserId.isNullOrBlank()) record.put("senderUserId", senderUserId)
        if (!senderName.isNullOrBlank()) record.put("senderName", senderName)
        if (!responseUrl.isNullOrBlank()) record.put("responseUrl", responseUrl)
        if (!kind.isNullOrBlank()) record.put("kind", kind)
        if (!record.has("arrivedAtMs")) record.put("arrivedAtMs", arrivedAtMs)
        if (!record.has("status")) record.put("status", "pending")
        records.put(eventId, record)
        writeAll(context, prune(records))
        DuoWidgetRenderer.updateAll(context)
    }

    /** First pending nudge for [groupId], if any — used to render the widget's
     *  pending-nudge state (decline | mic | accept) without waiting on RTDB. */
    fun pendingForGroup(context: Context, groupId: String): Map<String, String>? {
        val records = prune(readAll(context))
        val keys = records.keys()
        while (keys.hasNext()) {
            val eventId = keys.next()
            val record = records.optJSONObject(eventId) ?: continue
            if (record.optString("groupId", "") != groupId) continue
            if (record.optString("status", "pending") != "pending") continue
            return buildMap {
                put("eventId", record.optString("eventId", eventId))
                put("groupId", groupId)
                record.optString("senderUserId", "").takeIf { it.isNotBlank() }
                    ?.let { put("senderUserId", it) }
                record.optString("senderName", "").takeIf { it.isNotBlank() }
                    ?.let { put("senderName", it) }
                record.optString("responseUrl", "").takeIf { it.isNotBlank() }
                    ?.let { put("responseUrl", it) }
                record.optString("kind", "").takeIf { it.isNotBlank() }
                    ?.let { put("kind", it) }
            }
        }
        return null
    }

    fun markStatus(
        context: Context,
        eventId: String,
        status: String,
        snoozedUntilMs: Long? = null,
    ) {
        if (eventId.isBlank()) return
        val records = readAll(context)
        val record = records.optJSONObject(eventId) ?: org.json.JSONObject().apply {
            put("eventId", eventId)
            put("arrivedAtMs", System.currentTimeMillis())
        }
        record.put("status", status)
        if (snoozedUntilMs != null) record.put("snoozedUntilMs", snoozedUntilMs)
        records.put(eventId, record)
        writeAll(context, prune(records))
        DuoWidgetRenderer.updateAll(context)
    }

    fun list(context: Context): List<Map<String, Any>> {
        val records = prune(readAll(context))
        writeAll(context, records)
        val result = ArrayList<Map<String, Any>>()
        val keys = records.keys()
        while (keys.hasNext()) {
            val eventId = keys.next()
                val record = records.optJSONObject(eventId) ?: continue
            val map = mutableMapOf<String, Any>(
                "eventId" to record.optString("eventId", eventId),
                "groupId" to record.optString("groupId", ""),
                "arrivedAtMs" to record.optLong("arrivedAtMs", 0L),
                "status" to record.optString("status", "pending"),
            )
            record.optString("senderUserId", "").takeIf { it.isNotBlank() }
                ?.let { map["senderUserId"] = it }
            record.optString("senderName", "").takeIf { it.isNotBlank() }
                ?.let { map["senderName"] = it }
            record.optLong("snoozedUntilMs", 0L).takeIf { it > 0L }
                ?.let { map["snoozedUntilMs"] = it }
            result.add(map)
        }
        return result
    }

    private fun readAll(context: Context): org.json.JSONObject {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(payloadKey, null)
        return if (raw.isNullOrBlank()) org.json.JSONObject() else try {
            org.json.JSONObject(raw)
        } catch (_: Exception) {
            org.json.JSONObject()
        }
    }

    private fun writeAll(context: Context, records: org.json.JSONObject) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(payloadKey, records.toString())
            .apply()
    }

    private fun prune(records: org.json.JSONObject): org.json.JSONObject {
        val now = System.currentTimeMillis()
        val kept = org.json.JSONObject()
        val keys = records.keys()
        val snapshot = mutableListOf<String>()
        while (keys.hasNext()) snapshot.add(keys.next())
        for (eventId in snapshot) {
            val record = records.optJSONObject(eventId) ?: continue
            val arrivedAt = record.optLong("arrivedAtMs", now)
            val status = record.optString("status", "pending")
            val age = now - arrivedAt
            val retain = if (status == "pending") age <= expiryMs else age <= statusRetentionMs
            if (retain) kept.put(eventId, record)
        }
        return kept
    }
}

object IncomingNudgeDispatcher {
    @Volatile
    private var channel: MethodChannel? = null

    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    fun detach(methodChannel: MethodChannel) {
        if (channel === methodChannel) channel = null
    }

    fun signal(payload: Map<String, Any>) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("onIncomingNudge", payload)
        }
    }

    fun signalStatus(eventId: String, status: String, snoozedUntilMs: Long? = null) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod(
                "onIncomingNudgeStatus",
                buildMap<String, Any?> {
                    put("eventId", eventId)
                    put("status", status)
                    if (snoozedUntilMs != null) put("snoozedUntilMs", snoozedUntilMs)
                },
            )
        }
    }
}

class NudgeNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val responseAction = when (intent.action) {
            VoiceNudgeContract.actionDecline -> "decline"
            VoiceNudgeContract.actionSnooze -> "snooze"
            else -> return
        }
        val snoozeMinutes = if (responseAction == "snooze") {
            val selected = RemoteInput.getResultsFromIntent(intent)
                ?.getCharSequence(VoiceNudgeContract.extraSnoozeMinutes)
                ?.toString()
                ?.filter { it.isDigit() }
                ?.toIntOrNull()
            if (selected != 5 && selected != 15) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[NUDGE-ACTION-W2] Invalid snooze selection=$selected",
                )
                VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                    worker = "ACTION-W2",
                    kind = "nudge",
                    eventId = intent.getStringExtra(VoiceNudgeContract.extraEventId),
                    extras = mapOf(
                        "checkpoint" to "nudge_action_invalid_snooze",
                        "selected" to (selected?.toString() ?: "none"),
                    ),
                )
                return
            }
            selected
        } else {
            null
        }
        val responseUrl = intent.getStringExtra(VoiceNudgeContract.extraResponseUrl) ?: return
        val eventId = intent.getStringExtra(VoiceNudgeContract.extraEventId) ?: return
        val senderName = intent.getStringExtra(VoiceNudgeContract.extraSenderName) ?: "Friend"
        val notificationId = intent.getIntExtra(
            VoiceNudgeContract.extraNotificationId,
            VoiceNudgeNotifications.idFor(eventId),
        )
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        // B5: Cancel the expiry alarm for any user action (decline/snooze).
        NudgeExpiryTracker.cancelExpiry(appContext, eventId)
        val snoozedUntilMs = if (responseAction == "snooze" && snoozeMinutes != null) {
            System.currentTimeMillis() + snoozeMinutes * 60_000L
        } else {
            null
        }
        IncomingNudgeStore.markStatus(
            appContext,
            eventId,
            if (responseAction == "snooze") "snoozed" else "declined",
            snoozedUntilMs,
        )
        IncomingNudgeDispatcher.signalStatus(
            eventId,
            if (responseAction == "snooze") "snoozed" else "declined",
            snoozedUntilMs,
        )
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[NUDGE-ACTION-W1] No signed-in Firebase user")
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "ACTION-W1",
                kind = "nudge",
                eventId = eventId,
                extras = mapOf("checkpoint" to "nudge_action_no_firebase_user"),
            )
            pendingResult.finish()
            return
        }

        user.getIdToken(false).addOnCompleteListener { tokenTask ->
            val idToken = if (tokenTask.isSuccessful) tokenTask.result?.token else null
            if (idToken.isNullOrBlank()) {
                VoiceNudgeDiagnostics.logFailure(
                    "[NUDGE-ACTION-E1] Firebase ID token",
                    tokenTask.exception,
                )
                VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                    worker = "ACTION-E1",
                    error = tokenTask.exception,
                    kind = "nudge",
                    eventId = eventId,
                    extras = mapOf("checkpoint" to "nudge_action_id_token"),
                )
                pendingResult.finish()
                return@addOnCompleteListener
            }
            executor.execute {
                try {
                    postResponse(responseUrl, idToken, responseAction, snoozeMinutes)
                    VoiceNudgeAudioCache.delete(appContext, eventId)
                    val text = if (responseAction == "snooze") {
                        "You asked $senderName to wait $snoozeMinutes minutes ⏳"
                    } else {
                        "You declined $senderName's nudge 💤"
                    }
                    val manager = appContext.getSystemService(NotificationManager::class.java)
                    manager.notify(
                        notificationId,
                        VoiceNudgeNotifications.buildGeneral(
                            appContext,
                            "Nudge answered ✅",
                            text,
                        ),
                    )
                    Log.i(
                        VoiceNudgeDiagnostics.tag,
                        "[NUDGE-ACTION-01] response=$responseAction " +
                            "snoozeMinutes=${snoozeMinutes ?: "none"} " +
                            "eventSuffix=${eventId.takeLast(6)}",
                    )
                } catch (error: Exception) {
                    VoiceNudgeDiagnostics.logFailure("[NUDGE-ACTION-E2] Response upload", error)
                    VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                        worker = "ACTION-E2",
                        error = error,
                        kind = "nudge",
                        eventId = eventId,
                        extras = mapOf("checkpoint" to "nudge_action_response_upload"),
                    )
                } finally {
                    pendingResult.finish()
                }
            }
        }
    }

    private fun postResponse(
        responseUrl: String,
        idToken: String,
        action: String,
        snoozeMinutes: Int?,
    ) {
        val connection = URL(responseUrl).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 8_000
            connection.readTimeout = 8_000
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("authorization", "Bearer $idToken")
            connection.setRequestProperty("content-type", "application/json")
            connection.outputStream.use {
                val body = if (action == "snooze") {
                    "{\"action\":\"snooze\",\"snoozeMinutes\":$snoozeMinutes}"
                } else {
                    "{\"action\":\"$action\"}"
                }
                it.write(body.toByteArray())
            }
            val responseCode = connection.responseCode
            if (responseCode !in 200..299) {
                throw IllegalStateException("Nudge response failed with HTTP $responseCode")
            }
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        private val executor = Executors.newCachedThreadPool()
    }
}
