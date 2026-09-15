package app.oneone.one_one_app

import android.content.Context
import android.os.Build
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.crashlytics.FirebaseCrashlytics
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

object VoiceNudgeContract {
    const val flutterChannel = "app.oneone/voice_nudge"
    const val notificationChannelId = "voice_nudges"
    const val notificationChannelName = "Voice nudges"
    const val generalNotificationChannelId = "walkie_alerts_v2"
    const val generalNotificationChannelName = "Duo alerts"

    const val extraKind = "kind"
    const val extraEventId = "eventId"
    const val extraSenderName = "senderName"
    const val extraSenderUserId = "senderUserId"
    const val extraRecipientUserId = "recipientUserId"
    const val extraRecipientName = "recipientName"
    const val extraSenderPhotoUrl = "senderPhotoUrl"
    const val extraSenderAvatarAsset = "senderAvatarAsset"
    const val extraDurationMs = "durationMs"
    const val extraAudioUrl = "audioUrl"
    const val extraAckUrl = "ackUrl"
    const val extraDeliveryToken = "deliveryToken"
    const val extraGroupId = "groupId"
    const val extraResponseUrl = "responseUrl"
    const val extraAction = "nudgeAction"
    const val extraNotificationId = "notificationId"
    const val extraSnoozeMinutes = "snoozeMinutes"
    const val extraMessageId = "messageId"
    const val extraMessageText = "messageText"
    const val extraGroupName = "groupName"
    const val extraNotifyUrl = "notifyUrl"
    const val extraChatReply = "chatReply"

    const val kindVoice = "voice_nudge"
    const val kindRing = "ring_nudge"
    const val kindPush = "nudge"
    const val kindFriendLive = "friend_live"
    const val kindGoneOffline = "gone_offline"
    const val kindChatMessage = "chat_message"
    const val kindResponse = "nudge_response"
    const val kindDeliveryResult = "nudge_delivery_result"

    const val actionAccept = "app.oneone.action.ACCEPT_NUDGE"
    const val actionConnect = "app.oneone.action.CONNECT_NUDGE"
    const val actionOpenNudge = "app.oneone.action.OPEN_NUDGE"
    const val actionOpenChatPile = "app.oneone.action.OPEN_CHAT_PILE"
    const val actionReplyChat = "app.oneone.action.REPLY_CHAT"
    const val actionDecline = "app.oneone.action.DECLINE_NUDGE"
    const val actionSnooze = "app.oneone.action.SNOOZE_NUDGE"
    const val actionPlayCachedAudio = "app.oneone.action.PLAY_CACHED_NUDGE"
    const val actionPauseCachedAudio = "app.oneone.action.PAUSE_CACHED_NUDGE"
    const val actionDismissCachedAudio = "app.oneone.action.DISMISS_CACHED_NUDGE"
    const val actionStopGroupNudges = "app.oneone.action.STOP_GROUP_NUDGES"
}

object VoiceNudgeTokenStore {
    private const val preferencesName = "one_one_voice_nudge"
    private const val tokenKey = "fcm_token"

    fun save(context: Context, token: String) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(tokenKey, token)
            .apply()
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-05] Registered identifier saved locally " +
                VoiceNudgeDiagnostics.describeIdentifier(token),
        )
    }
}

// ── Delivery ack for failures that happen before VoiceNudgePlaybackService
// ever gets a chance to run (e.g. the OS rejects the foreground-service
// launch) ──
//
// VoiceNudgePlaybackService.acknowledge() already POSTs a rich ack (with
// health data) once the service is running. But when the
// service never starts at all, nothing ever calls that, so the sender was
// previously left with no signal beyond a generic ~12s client-side timeout
// with no specific reason. This lightweight, fire-and-forget helper lets the
// FCM receiver (which always has the ackUrl/deliveryToken from the payload)
// report a specific failure reason immediately in that case.
object VoiceNudgeDeliveryAck {
    private val executor = Executors.newSingleThreadExecutor()

    fun postPlayed(ackUrl: String?, deliveryToken: String?) {
        post(ackUrl, deliveryToken, status = "played", reason = null)
    }

    fun postFailure(ackUrl: String?, deliveryToken: String?, reason: String) {
        post(ackUrl, deliveryToken, status = "failed", reason = reason)
    }

    /**
     * Conclusive sender status via RTDB (required). Optional HTTP ack is
     * audit-only and must not be treated as the status path.
     */
    fun reportStatus(
        status: String,
        reason: String? = null,
        attention: String? = null,
        senderUserId: String?,
        eventId: String?,
        groupId: String?,
        kind: String?,
        ackUrl: String? = null,
        deliveryToken: String? = null,
        recipientUserId: String? = null,
        recipientName: String? = null,
    ) {
        NudgeDeliveryStatusRtdb.write(
            senderUserId = senderUserId,
            eventId = eventId,
            groupId = groupId,
            kind = kind,
            status = status,
            reason = reason,
            attention = attention,
            recipientUserId = recipientUserId,
            recipientName = recipientName,
        )
        // Legacy audit POST — fire-and-forget; sender UI does not depend on it.
        if (!ackUrl.isNullOrBlank() && !deliveryToken.isNullOrBlank()) {
            post(ackUrl, deliveryToken, status = status, reason = reason)
        }
    }

    fun reportFromFcmData(
        data: Map<String, String>,
        status: String,
        reason: String? = null,
        attention: String? = null,
    ) {
        reportStatus(
            status = status,
            reason = reason,
            attention = attention,
            senderUserId = data["senderUserId"],
            eventId = data["eventId"],
            groupId = data["groupId"],
            kind = data["kind"] ?: data["type"],
            ackUrl = data["ackUrl"],
            deliveryToken = data["deliveryToken"],
            recipientUserId = data["recipientUserId"],
            recipientName = data["recipientName"],
        )
    }

    private fun post(
        ackUrl: String?,
        deliveryToken: String?,
        status: String,
        reason: String?,
    ) {
        if (ackUrl.isNullOrBlank() || deliveryToken.isNullOrBlank()) return
        executor.execute {
            var connection: HttpURLConnection? = null
            try {
                val opened = URL(ackUrl).openConnection() as HttpURLConnection
                connection = opened
                opened.connectTimeout = 5_000
                opened.readTimeout = 5_000
                opened.requestMethod = "POST"
                opened.doOutput = true
                opened.setRequestProperty("content-type", "application/json")
                opened.setRequestProperty("x-one-one-delivery-token", deliveryToken)
                val body = JSONObject().apply {
                    put("status", status)
                    if (!reason.isNullOrBlank()) put("reason", reason)
                }
                opened.outputStream.use { it.write(body.toString().toByteArray()) }
                val responseCode = opened.responseCode
                Log.i(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-E3-ACK] Audit $status before/without playback " +
                        "reason=${reason ?: "none"} HTTP=$responseCode",
                )
            } catch (error: Exception) {
                VoiceNudgeDiagnostics.logFailure(
                    "[FCM-E3-ACK] Reporting $status",
                    error,
                )
            } finally {
                connection?.disconnect()
            }
        }
    }
}

object VoiceNudgeDiagnostics {
    const val tag = "OneOneFCM"

    fun describeIdentifier(value: String): String =
        "length=${value.length} suffix=${value.takeLast(6)}"

    fun logFailure(checkpoint: String, error: Throwable?) {
        if (error == null) {
            Log.e(tag, "$checkpoint failed without an exception")
            return
        }

        Log.e(tag, "$checkpoint ${error.javaClass.name}: ${error.message}", error)
        var cause = error.cause
        var depth = 1
        while (cause != null && cause !== error && depth <= 6) {
            Log.e(
                tag,
                "$checkpoint cause[$depth]=${cause.javaClass.name}: ${cause.message}",
            )
            cause = cause.cause
            depth += 1
        }
    }

    // ── B3: Comprehensive nudge failure logging to Crashlytics ──
    //
    // Every nudge failure is recorded as a non-fatal Crashlytics event with
    // enough metadata to debug without manual reproduction.  All events use
    // the custom key "nudge_failure_event" so they are filterable in the
    // dashboard.

    fun canonicalFailureReason(reason: String): String = when (reason) {
        "permission_denied_microphone" -> "permission_denied_microphone"
        "permission_denied_firebase" -> "permission_denied_firebase"
        "fcm_not_delivered" -> "fcm_not_delivered"
        "download_failed", "download_error" -> "download_failed"
        "playback_failed", "playback_error", "playback_service_start_error", "timeout" ->
            "playback_failed"
        "volume_too_low", "volume_low", "volume_very_low", "volume_muted" -> "volume_too_low"
        "dnd_active" -> "dnd_active"
        "livekit_session_failed" -> "livekit_session_failed"
        "background_fg_service_blocked", "permission_denied_foreground_service" ->
            "background_fg_service_blocked"
        "permission_denied_notifications" -> "permission_denied_notifications"
        "battery_optimization_active" -> "battery_optimization_active"
        "app_force_stopped" -> "app_force_stopped"
        else -> "unknown"
    }

    /**
     * Generic nudge-failure record with a required reason code.
     *
     * Records a non-fatal Crashlytics event so playback/delivery failures show
     * up in the console even when the app never crashes.
     */
    fun recordNudgeFailure(
        reason: String,
        eventId: String?,
        kind: String?,
        extras: Map<String, String> = emptyMap(),
        groupId: String? = null,
        senderUserId: String? = null,
        senderName: String? = null,
        health: Map<String, String> = emptyMap(),
        throwable: Throwable? = null,
    ) {
        val crashlytics = FirebaseCrashlytics.getInstance()
        val receiverUserId = FirebaseAuth.getInstance().currentUser?.uid
        val canonical = canonicalFailureReason(reason)
        val network = DeviceLog.networkMeta()
        val device = DeviceLog.deviceMeta()
        val inBackground = DeviceLog.wasAppInBackground()

        crashlytics.setCustomKey("nudge_sender_id", senderUserId.orEmpty())
        crashlytics.setCustomKey("nudge_receiver_id", receiverUserId.orEmpty())
        crashlytics.setCustomKey("group_id", groupId.orEmpty())
        crashlytics.setCustomKey("failure_reason", canonical)
        crashlytics.setCustomKey("network_type", network["networkType"] ?: "Unknown")
        crashlytics.setCustomKey("device_model", device["deviceModel"] ?: Build.MODEL)
        crashlytics.setCustomKey("android_version", Build.VERSION.RELEASE ?: "")
        crashlytics.setCustomKey("app_version", DeviceLog.currentAppVersion())
        crashlytics.setCustomKey("was_app_in_background", inBackground)
        crashlytics.setCustomKey("livekit_room_state", extras["livekit_room_state"] ?: "")
        crashlytics.setCustomKey("nudge_failure_event", canonical)
        crashlytics.setCustomKey("nudge_failure_kind", kind ?: "unknown")
        crashlytics.setCustomKey("device_manufacturer", Build.MANUFACTURER)
        crashlytics.setCustomKey("android_sdk", Build.VERSION.SDK_INT.toString())
        crashlytics.setCustomKey("network_strength", network["networkStrength"] ?: "-")
        receiverUserId?.let { crashlytics.setUserId(it) }
        eventId?.let {
            crashlytics.setCustomKey("nudge_event_suffix", it.takeLast(8))
        }
        senderName?.let { crashlytics.setCustomKey("sender_name", it.take(40)) }
        for ((key, value) in extras) {
            crashlytics.setCustomKey(key, value)
        }
        for ((key, value) in health) {
            crashlytics.setCustomKey("health_$key", value)
        }
        val trace = NudgeLogBuffer.snapshot()
        crashlytics.log("nudge_trace_begin reason=$canonical kind=$kind lines=${trace.size}")
        for (line in trace) {
            crashlytics.log(line)
        }
        crashlytics.log("nudge_trace_end")
        crashlytics.recordException(
            throwable
                ?: RuntimeException(
                    "Nudge failure: $canonical (kind=$kind eventSuffix=${eventId?.takeLast(6) ?: "none"})",
                ),
        )
        Log.w(
            tag,
            "[NUDGE-FAIL] reason=$canonical kind=$kind " +
                "groupId=${groupId?.takeLast(6) ?: "none"} " +
                "receiver=${receiverUserId?.takeLast(6) ?: "none"} ${extras}",
        )
    }

    /**
     * Non-fatal FCM notification-handling failure.
     *
     * Filterable in Crashlytics by custom key
     * `reason=fcm_notification_handling_failure`. Worker / channel identifiers
     * stay in this report and logcat — never in user-facing UI.
     */
    fun recordFcmHandlingFailure(
        worker: String,
        error: Throwable? = null,
        kind: String? = null,
        eventId: String? = null,
        groupId: String? = null,
        extras: Map<String, String> = emptyMap(),
    ) {
        val crashlytics = FirebaseCrashlytics.getInstance()
        val inBackground = DeviceLog.wasAppInBackground()
        val information = fcmHandlingInformation(
            worker = worker,
            groupId = groupId,
            eventId = eventId,
            kind = kind,
            inBackground = inBackground,
        )
        crashlytics.setCustomKey("reason", FCM_HANDLING_FAILURE_REASON)
        crashlytics.setCustomKey("fcm_worker", worker)
        crashlytics.setCustomKey("fcm_kind", kind.orEmpty())
        crashlytics.setCustomKey("group_id", groupId.orEmpty())
        crashlytics.setCustomKey("nudge_event_id", eventId.orEmpty())
        crashlytics.setCustomKey("was_app_in_background", inBackground)
        for (line in information) {
            crashlytics.log(line)
        }
        for ((key, value) in extras) {
            crashlytics.setCustomKey(key, value)
        }
        val throwable = RuntimeException(
            "$FCM_HANDLING_FAILURE_REASON worker=$worker kind=${kind ?: "-"} " +
                "eventId=${eventId ?: "-"} groupId=${groupId ?: "-"}",
            error,
        )
        crashlytics.recordException(throwable)
        Log.w(
            tag,
            "[$worker] $FCM_HANDLING_FAILURE_REASON kind=${kind ?: "-"} " +
                "groupId=${groupId?.takeLast(6) ?: "none"} " +
                "eventId=${eventId?.takeLast(6) ?: "none"} " +
                "appState=${if (inBackground) "background" else "foreground"}",
        )
    }
}
