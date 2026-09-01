package app.oneone.one_one_app

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

// ── B5: Local nudge expiry (10-minute timeout, on-device) ──
//
// When a nudge arrives on the receiver's device we record its wall-clock
// deadline and schedule an AlarmManager broadcast. If the broadcast fires
// and the nudge hasn't been accepted yet:
//   • Ring: cancel the (possibly batched) shade notification
//   • Voice: strip Accept/Decline but keep Play when audio is cached
//   • Sender-side / other: show a local expiry toast
// Cancel only on accept / decline / snooze — delivery ("played") must not
// clear the accept window. Deadlines use RTC so reconcile() can re-arm after
// process death / backgrounding.

object NudgeExpiryTracker {
    private const val prefsName = "one_one_nudge_expiry"
    private const val keyPrefix = "nudge_arrival_"
    private const val metaPrefix = "nudge_meta_"
    const val expiryMinutes = 10L
    const val expiryMs = expiryMinutes * 60_000L
    const val actionExpiry = "app.oneone.action.NUDGE_EXPIRED"

    data class ExpiryMeta(
        val eventId: String,
        val arrivedAtMs: Long,
        val deadlineAtMs: Long,
        val senderName: String,
        val groupId: String?,
        val groupName: String?,
        val kind: String?,
        val notificationId: Int?,
        val isSenderSide: Boolean,
        val memberEventIds: List<String>,
    )

    /** Record a nudge arrival and schedule its expiry alarm. */
    fun scheduleExpiry(
        context: Context,
        eventId: String,
        senderName: String,
        recipientUserId: String?,
        groupId: String?,
        recipientName: String?,
        isSenderSide: Boolean = false,
        kind: String? = null,
        notificationId: Int? = null,
        groupName: String? = null,
        deadlineAtMs: Long? = null,
        memberEventIds: List<String> = emptyList(),
    ) {
        val now = System.currentTimeMillis()
        val deadline = deadlineAtMs ?: (now + expiryMs)
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val meta = org.json.JSONObject().apply {
            put("eventId", eventId)
            put("arrivedAtMs", now)
            put("deadlineAtMs", deadline)
            put("senderName", senderName)
            put("isSenderSide", isSenderSide)
            if (!groupId.isNullOrBlank()) put("groupId", groupId)
            if (!groupName.isNullOrBlank()) put("groupName", groupName)
            if (!kind.isNullOrBlank()) put("kind", kind)
            if (notificationId != null) put("notificationId", notificationId)
            if (!recipientUserId.isNullOrBlank()) put("recipientUserId", recipientUserId)
            if (!recipientName.isNullOrBlank()) put("recipientName", recipientName)
            if (memberEventIds.isNotEmpty()) {
                put("memberEventIds", org.json.JSONArray(memberEventIds))
            }
        }
        prefs.edit()
            .putLong("${keyPrefix}$eventId", now)
            .putString("${metaPrefix}$eventId", meta.toString())
            .apply()

        armAlarm(context, eventId, deadline)
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-EXPIRY-00] Scheduled expiry eventSuffix=${eventId.takeLast(6)} " +
                "kind=${kind ?: "none"} senderSide=$isSenderSide " +
                "in=${((deadline - now) / 1000).coerceAtLeast(0)}s",
        )
    }

    /** Cancel the expiry alarm — accept / decline / snooze only. */
    fun cancelExpiry(context: Context, eventId: String) {
        if (eventId.isBlank()) return
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        prefs.edit()
            .remove("${keyPrefix}$eventId")
            .remove("${metaPrefix}$eventId")
            .apply()

        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, NudgeExpiryReceiver::class.java).apply {
            action = actionExpiry
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            eventId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager.cancel(pendingIntent)
    }

    /** Check if a nudge has been stored (hasn't expired and hasn't been accepted). */
    fun hasArrived(context: Context, eventId: String): Boolean {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        return prefs.contains("${keyPrefix}$eventId")
    }

    fun readMeta(context: Context, eventId: String): ExpiryMeta? {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val raw = prefs.getString("${metaPrefix}$eventId", null) ?: return null
        return try {
            val obj = org.json.JSONObject(raw)
            val membersJson = obj.optJSONArray("memberEventIds")
            val members = buildList {
                if (membersJson != null) {
                    for (i in 0 until membersJson.length()) {
                        val id = membersJson.optString(i).trim()
                        if (id.isNotEmpty()) add(id)
                    }
                }
            }
            ExpiryMeta(
                eventId = obj.optString("eventId", eventId),
                arrivedAtMs = obj.optLong("arrivedAtMs", 0L),
                deadlineAtMs = obj.optLong("deadlineAtMs", 0L),
                senderName = obj.optString("senderName", "Someone"),
                groupId = obj.optString("groupId").takeIf { it.isNotBlank() },
                groupName = obj.optString("groupName").takeIf { it.isNotBlank() },
                kind = obj.optString("kind").takeIf { it.isNotBlank() },
                notificationId = if (obj.has("notificationId")) obj.optInt("notificationId") else null,
                isSenderSide = obj.optBoolean("isSenderSide", false),
                memberEventIds = members,
            )
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Re-arm or immediately apply overdue expiries using wall-clock deadlines.
     * Call on cold start so Accept/Decline windows stay correct after restart.
     */
    fun reconcile(context: Context) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val eventIds = prefs.all.keys.mapNotNull { key ->
            when {
                key.startsWith(metaPrefix) -> key.removePrefix(metaPrefix)
                key.startsWith(keyPrefix) -> key.removePrefix(keyPrefix)
                else -> null
            }
        }.filter { it.isNotBlank() }.toSet()
        for (eventId in eventIds) {
            val meta = readMeta(context, eventId)
            val deadline = meta?.deadlineAtMs
                ?: (prefs.getLong("${keyPrefix}$eventId", 0L).takeIf { it > 0L }?.plus(expiryMs))
                ?: continue
            if (deadline <= now) {
                NudgeExpiryReceiver.applyExpiry(context, eventId, meta)
            } else {
                armAlarm(context, eventId, deadline)
            }
        }
    }

    private fun armAlarm(context: Context, eventId: String, deadlineAtMs: Long) {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, NudgeExpiryReceiver::class.java).apply {
            action = actionExpiry
            putExtra("eventId", eventId)
        }
        // Attach display fields from meta so the receiver works even if prefs
        // are partially pruned; reconcile/applyExpiry prefer prefs meta.
        readMeta(context, eventId)?.let { meta ->
            intent.putExtra("senderName", meta.senderName)
            intent.putExtra("groupId", meta.groupId)
            intent.putExtra("isSenderSide", meta.isSenderSide)
            intent.putExtra("kind", meta.kind)
            meta.notificationId?.let { intent.putExtra("notificationId", it) }
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            eventId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    deadlineAtMs,
                    pendingIntent,
                )
            } else {
                @Suppress("DEPRECATION")
                alarmManager.setExact(
                    AlarmManager.RTC_WAKEUP,
                    deadlineAtMs,
                    pendingIntent,
                )
            }
        } catch (_: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    deadlineAtMs,
                    pendingIntent,
                )
            } else {
                @Suppress("DEPRECATION")
                alarmManager.set(AlarmManager.RTC_WAKEUP, deadlineAtMs, pendingIntent)
            }
        }
    }
}

class NudgeExpiryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NudgeExpiryTracker.actionExpiry) return
        val eventId = intent.getStringExtra("eventId") ?: return
        applyExpiry(context, eventId, NudgeExpiryTracker.readMeta(context, eventId))
    }

    companion object {
        fun applyExpiry(
            context: Context,
            eventId: String,
            meta: NudgeExpiryTracker.ExpiryMeta?,
        ) {
            if (!NudgeExpiryTracker.hasArrived(context, eventId)) return
            NudgeExpiryTracker.cancelExpiry(context, eventId)

            val appContext = context.applicationContext
            val senderName = meta?.senderName ?: "Someone"
            val groupId = meta?.groupId
            val isSenderSide = meta?.isSenderSide == true
            val kind = meta?.kind
            val manager = appContext.getSystemService(NotificationManager::class.java)

            if (isSenderSide) {
                manager.notify(
                    VoiceNudgeNotifications.idFor("expiry_sender_$eventId"),
                    VoiceNudgeNotifications.buildGeneral(
                        appContext,
                        "Nudge expired ⏰",
                        "Your nudge to $senderName was not accepted in time.",
                        groupId,
                    ),
                )
                Log.i(
                    VoiceNudgeDiagnostics.tag,
                    "[NUDGE-EXPIRY-02] Sender nudge expired eventId=${eventId.takeLast(6)} " +
                        "recipient=$senderName",
                )
                return
            }

            when (kind) {
                VoiceNudgeContract.kindRing -> {
                    val members = meta?.memberEventIds?.takeIf { it.isNotEmpty() }
                        ?: listOf(eventId)
                    val batch = members.firstOrNull()?.let {
                        RingNudgeBatchStore.batchForEvent(appContext, it)
                    }
                    val notificationId = meta?.notificationId
                        ?: batch?.notificationId
                        ?: VoiceNudgeNotifications.idFor(eventId)
                    manager.cancel(notificationId)
                    // Drop the separate "expired" toast — the ring slab itself
                    // disappearing is the signal; Accept/Decline are gone with it.
                    for (memberId in members) {
                        NudgeExpiryTracker.cancelExpiry(appContext, memberId)
                        // Keep status pending so we do not fake a user decline;
                        // Flutter drops prompts via sentAt + 10 min.
                    }
                    if (batch != null) {
                        RingNudgeBatchStore.clearBatch(appContext, batch.groupId)
                    } else {
                        for (memberId in members) {
                            RingNudgeBatchStore.clearForEvent(appContext, memberId)
                        }
                    }
                    Log.i(
                        VoiceNudgeDiagnostics.tag,
                        "[NUDGE-EXPIRY-01] Ring batch expired " +
                            "eventId=${eventId.takeLast(6)} members=${members.size}",
                    )
                }
                VoiceNudgeContract.kindVoice -> {
                    val notificationId = meta?.notificationId
                        ?: VoiceNudgeNotifications.idFor(eventId)
                    val cached = VoiceNudgeAudioCache.file(appContext, eventId).isFile
                    if (cached) {
                        // Strip Accept/Decline (null responseUrl) but keep Play.
                        manager.notify(
                            notificationId,
                            VoiceNudgeNotifications.build(
                                context = appContext,
                                eventId = eventId,
                                groupId = groupId.orEmpty(),
                                responseUrl = null,
                                senderName = senderName,
                                status = "Voice nudge received 🎙️",
                                ongoing = false,
                                cachedAudioAvailable = true,
                                isPlaying = false,
                                largeIcon = NotificationAvatarHelper.largeIcon(
                                    appContext,
                                    null,
                                    senderName,
                                    null,
                                ),
                                groupName = meta?.groupName,
                                notificationId = notificationId,
                            ),
                        )
                    }
                    // If cache is gone, leave the existing shade entry alone —
                    // Accept/Decline are already past the Flutter prompt window.
                    Log.i(
                        VoiceNudgeDiagnostics.tag,
                        "[NUDGE-EXPIRY-01] Voice accept window expired " +
                            "eventId=${eventId.takeLast(6)} keepPlay=$cached",
                    )
                }
                else -> {
                    manager.notify(
                        VoiceNudgeNotifications.idFor("expiry_recv_$eventId"),
                        VoiceNudgeNotifications.buildGeneral(
                            appContext,
                            "Nudge expired ⏰",
                            "Nudge from $senderName has expired.",
                            groupId,
                        ),
                    )
                    Log.i(
                        VoiceNudgeDiagnostics.tag,
                        "[NUDGE-EXPIRY-01] Receiver nudge expired " +
                            "eventId=${eventId.takeLast(6)} sender=$senderName",
                    )
                }
            }
        }
    }
}

class VoiceNudgeMessagingService : FirebaseMessagingService() {
    override fun onRegistered(installationId: String) {
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-06] onRegistered callback " +
                VoiceNudgeDiagnostics.describeIdentifier(installationId),
        )
        VoiceNudgeTokenStore.save(this, installationId)
        NudgeActionDispatcher.signalRegistrationRenewed()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        DeviceLog.init(this)
        val data = message.data
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-07] Message received id=${message.messageId ?: "none"} " +
                "keys=${data.keys.sorted().joinToString(",")}",
        )
        try {
            dispatchMessage(message)
        } catch (error: Exception) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E1] Message handling", error)
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "FCM-E1",
                error = error,
                kind = data["type"],
                eventId = data["eventId"],
                groupId = data["groupId"],
            )
        }
    }

    private fun dispatchMessage(message: RemoteMessage) {
        val data = message.data
        val kind = data["type"]
        if (kind == VoiceNudgeContract.kindVoice ||
            kind == VoiceNudgeContract.kindRing ||
            kind == VoiceNudgeContract.kindPush
        ) {
            MediaVolume.report(this, data["groupId"])
            // Note: do NOT pass userId=data["senderUserId"] here. The structured
            // context field must reflect *this* device (the receiver), not the
            // sender — otherwise the log looks like the sender received it.
            DeviceLog.info(
                "NudgeService",
                "FCM trigger received kind=$kind eventId=${data["eventId"] ?: "-"} " +
                    "sender=${data["senderName"] ?: "-"} " +
                    "senderUserId=${data["senderUserId"] ?: "-"}",
                groupId = data["groupId"],
            )
            if (kind == VoiceNudgeContract.kindVoice || kind == VoiceNudgeContract.kindRing) {
                DeviceLog.info(
                    "NudgeService",
                    "VOICE_NUDGE_RECEIVED nudgeId=${data["eventId"] ?: "-"} kind=$kind",
                    groupId = data["groupId"],
                )
            }
        }
        if (kind == null) {
            if (message.notification != null) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-W1] Legacy notification has no type; displaying foreground fallback",
                )
                VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                    worker = "W1",
                    kind = "legacy_notification",
                    eventId = data["eventId"] ?: message.messageId,
                    groupId = data["groupId"],
                    extras = mapOf("checkpoint" to "fcm_legacy_notification_no_type"),
                )
                showForegroundNotification(message, "legacy_notification")
                return
            }
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W1] Ignored data message without type")
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W1",
                eventId = data["eventId"] ?: message.messageId,
                groupId = data["groupId"],
                extras = mapOf("checkpoint" to "fcm_data_message_no_type"),
            )
            return
        }
        when (kind) {
            "group_removed",
            "group_deleted" -> {
                showGroupLifecycleNotification(message)
                return
            }
            VoiceNudgeContract.kindGoneOffline -> {
                showGoneOfflineNotification(message)
                return
            }
            VoiceNudgeContract.kindPush -> {
                // B5: Schedule 10-min expiry for push nudges.
                scheduleNudgeExpiry(data)
                recordIncomingNudge(data)
                showActionableNotification(message)
                data["groupId"]?.takeIf { it.isNotBlank() }
                    ?.let { NudgeReceivedDispatcher.signal(it) }
                return
            }
            VoiceNudgeContract.kindFriendLive -> {
                showForegroundNotification(message, kind)
                return
            }
            VoiceNudgeContract.kindChatMessage -> {
                showChatPileNotification(message)
                return
            }
            VoiceNudgeContract.kindResponse -> {
                showNudgeResponse(message)
                return
            }
            VoiceNudgeContract.kindDeliveryResult -> {
                forwardDeliveryResult(message)
                return
            }
            VoiceNudgeContract.kindVoice,
            VoiceNudgeContract.kindRing -> Unit
            else -> {
                Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W2] Ignored unknown message type=$kind")
                VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                    worker = "W2",
                    kind = kind,
                    eventId = data["eventId"] ?: message.messageId,
                    groupId = data["groupId"],
                    extras = mapOf("checkpoint" to "fcm_unknown_message_type"),
                )
                return
            }
        }

        // B5: Schedule 10-min expiry for voice + ring nudges.
        scheduleNudgeExpiry(data)

        val eventId = data["eventId"]
        if (eventId == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W3] Ignored $kind without eventId")
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W3",
                kind = kind,
                groupId = data["groupId"],
                extras = mapOf("checkpoint" to "fcm_missing_event_id"),
            )
            return
        }
        val groupId = data["groupId"]?.takeIf { it.isNotBlank() }
        if (groupId == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W10] Ignored $kind without groupId")
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W10",
                kind = kind,
                eventId = eventId,
                extras = mapOf("checkpoint" to "fcm_missing_group_id"),
            )
            return
        }

        // Prefetch/warm the LiveKit connection while playback starts so the
        // accept -> connected path is faster.
        NudgeReceivedDispatcher.signal(groupId)
        recordIncomingNudge(data)
        val senderName = data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val senderPhotoUrl = data["senderPhotoUrl"]?.takeIf { it.isNotBlank() }
        val senderAvatarAsset = data["senderAvatarAsset"]?.takeIf { it.isNotBlank() }
        val durationMs = data["durationMs"]?.toLongOrNull()?.coerceIn(250L, 10_000L)
        if (durationMs == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W4] Ignored $kind with invalid duration")
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W4",
                kind = kind,
                eventId = eventId,
                groupId = groupId,
                extras = mapOf("checkpoint" to "fcm_invalid_duration"),
            )
            return
        }
        if (kind == VoiceNudgeContract.kindVoice && isExpired(data["expiresAt"])) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W5] Ignored expired voice nudge")
            DeviceLog.warn(
                "NudgeService",
                "Nudge not delivered: unknown (expired before playback) eventId=$eventId",
                groupId = groupId,
            )
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W5",
                kind = kind,
                eventId = eventId,
                groupId = groupId,
                extras = mapOf("checkpoint" to "fcm_expired_voice"),
            )
            return
        }

        val intent = Intent(this, VoiceNudgePlaybackService::class.java).apply {
            putExtra(VoiceNudgeContract.extraKind, kind)
            putExtra(VoiceNudgeContract.extraEventId, eventId)
            putExtra(VoiceNudgeContract.extraSenderName, senderName)
            putExtra(VoiceNudgeContract.extraGroupName, data["groupName"])
            putExtra(VoiceNudgeContract.extraSenderUserId, data["senderUserId"])
            putExtra(VoiceNudgeContract.extraSenderPhotoUrl, senderPhotoUrl)
            putExtra(VoiceNudgeContract.extraSenderAvatarAsset, senderAvatarAsset)
            putExtra(VoiceNudgeContract.extraDurationMs, durationMs)
            putExtra(VoiceNudgeContract.extraAudioUrl, data["audioUrl"])
            putExtra(VoiceNudgeContract.extraAckUrl, data["ackUrl"])
            putExtra(VoiceNudgeContract.extraDeliveryToken, data["deliveryToken"])
            putExtra(VoiceNudgeContract.extraGroupId, groupId)
            putExtra(VoiceNudgeContract.extraResponseUrl, data["responseUrl"])
        }

        try {
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-09] Starting native playback kind=$kind eventSuffix=${eventId.takeLast(6)}",
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E3] Native playback start", error)
            val failureReason =
                if (error is SecurityException) "background_fg_service_blocked" else "playback_failed"
            DeviceLog.log(
                "ERROR",
                "NudgeService",
                "Nudge not delivered: ${nudgeUndeliveredReason(error)} " +
                    "kind=$kind eventId=$eventId",
                groupId = groupId,
                throwable = error,
            )
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "E3",
                error = error,
                kind = kind,
                eventId = eventId,
                groupId = groupId,
                extras = mapOf(
                    "error" to (error.message ?: "unknown"),
                    "error_class" to error.javaClass.simpleName,
                    "checkpoint" to "fcm_start_playback_service",
                    "failure_reason" to failureReason,
                ),
            )
            // The playback service never got a chance to run (and therefore
            // never got to POST its own ack) — report the specific reason
            // directly so the sender doesn't just see a generic timeout.
            VoiceNudgeDeliveryAck.reportFromFcmData(
                data,
                status = "failed",
                reason = failureReason,
            )
            val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
            val notificationId = VoiceNudgeNotifications.idFor(eventId)
            NotificationAvatarHelper.applyLargeIcon(
                this,
                data["senderPhotoUrl"],
                senderName,
                data["senderAvatarAsset"],
            ) { largeIcon ->
                try {
                    manager.notify(
                        notificationId,
                        VoiceNudgeNotifications.build(
                            this,
                            eventId,
                            groupId,
                            data["responseUrl"],
                            senderName,
                            "Tap to open this nudge 👋",
                            ongoing = false,
                            largeIcon = largeIcon,
                            senderUserId = data["senderUserId"],
                            groupName = data["groupName"],
                        ),
                    )
                } catch (error: SecurityException) {
                    VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
                }
            }
        }
    }

    override fun onDeletedMessages() {
        Log.w(
            VoiceNudgeDiagnostics.tag,
            "[FCM-W7] FCM deleted pending messages before delivery",
        )
        VoiceNudgeDiagnostics.recordFcmHandlingFailure(
            worker = "W7",
            kind = "fcm",
            extras = mapOf("checkpoint" to "onDeletedMessages"),
        )
    }

    private fun showGroupLifecycleNotification(message: RemoteMessage) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val groupId = message.data["groupId"] ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.activeNotifications
                .filter { it.notification.group == VoiceNudgeNotifications.groupKey(groupId) }
                .forEach { manager.cancel(it.id) }
        } else {
            manager.cancelAll()
        }
        try {
            startService(
                Intent(this, VoiceNudgePlaybackService::class.java).apply {
                    action = VoiceNudgeContract.actionStopGroupNudges
                    putExtra(VoiceNudgeContract.extraGroupId, groupId)
                },
            )
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E11] Group nudge cleanup", error)
        }
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor(message.messageId ?: "group_lifecycle"),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.data["title"] ?: "👥 Group updated",
                    message.data["body"] ?: "Your group membership changed.",
                    groupId,
                ),
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showChatPileNotification(message: RemoteMessage) {
        val groupId = message.data["groupId"]?.takeIf { it.isNotBlank() } ?: return
        // Foreground + already viewing this group: bubbles are on screen, so
        // skip the shade. Other groups (and all background deliveries) still
        // notify — do not broaden this gate to every foreground chat.
        if (!DeviceLog.wasAppInBackground() && DeviceLog.currentGroupId() == groupId) {
            ChatPileStore.reset(this, groupId)
            VoiceNudgeNotifications.cancelChatPile(this, groupId)
            return
        }
        val groupName = message.data["groupName"]?.takeIf { it.isNotBlank() } ?: "your group"
        val senderName = message.data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val senderUserId = message.data["senderUserId"].orEmpty()
        val text = message.data["messageText"]?.takeIf { it.isNotBlank() }
            ?: message.data["body"]?.takeIf { it.isNotBlank() }
            ?: "$senderName sent a message"
        val messageId = message.data["messageId"]?.takeIf { it.isNotBlank() }
            ?: message.messageId
            ?: "${System.currentTimeMillis()}"
        val senderPhotoUrl = message.data["senderPhotoUrl"]?.takeIf { it.isNotBlank() }
        val senderAvatarAsset = message.data["senderAvatarAsset"]?.takeIf { it.isNotBlank() }
        ChatPileStore.append(
            this,
            groupId = groupId,
            groupName = groupName,
            messageId = messageId,
            senderUserId = senderUserId,
            senderName = senderName,
            text = text,
            notifyUrl = message.data["notifyUrl"],
            senderPhotoUrl = senderPhotoUrl,
            senderAvatarAsset = senderAvatarAsset,
        )
        val conversation = ChatPileStore.conversation(this, groupId) ?: return
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val latestIncoming = conversation.messages.lastOrNull { !it.fromSelf }
        val iconLine = latestIncoming ?: conversation.messages.lastOrNull()
        try {
            if (iconLine == null) {
                manager.notify(
                    VoiceNudgeNotifications.chatPileId(groupId),
                    VoiceNudgeNotifications.buildChatConversation(this, conversation),
                )
            } else {
                NotificationAvatarHelper.applyLargeIcon(
                    this,
                    iconLine.senderPhotoUrl,
                    iconLine.senderName,
                    iconLine.senderAvatarAsset,
                ) { bitmap ->
                    manager.notify(
                        VoiceNudgeNotifications.chatPileId(groupId),
                        VoiceNudgeNotifications.buildChatConversation(
                            this,
                            conversation,
                            largeIconOverride = bitmap,
                        ),
                    )
                }
            }
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Chat notification displayed groupSuffix=${groupId.takeLast(6)} " +
                    "messages=${conversation.messages.size}",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showGoneOfflineNotification(message: RemoteMessage) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val groupId = message.data["groupId"]
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor(
                    message.messageId ?: "gone_offline_${message.sentTime}",
                ),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.data["title"] ?: "😴 You're offline",
                    message.data["body"] ?: "You are now offline.",
                    groupId,
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Gone-offline notification displayed reason=${message.data["reason"]}",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showForegroundNotification(message: RemoteMessage, kind: String) {
        val senderName = message.data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val groupName = message.data["groupName"]?.take(80).orEmpty()
        val fallbackTitle = if (kind == VoiceNudgeContract.kindFriendLive) {
            "🟢 $senderName is live"
        } else {
            "👋 $senderName nudged you${if (groupName.isBlank()) "" else " in $groupName"}"
        }
        val fallbackBody = if (kind == VoiceNudgeContract.kindFriendLive) {
            "Tap to open Duo 🎙️"
        } else {
            "Come online on Duo ✨"
        }
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val notificationKey = message.messageId ?: "${kind}_${message.sentTime}"
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor(notificationKey),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.notification?.title ?: fallbackTitle,
                    message.notification?.body ?: fallbackBody,
                    message.data["groupId"],
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Foreground notification displayed type=$kind",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showActionableNotification(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: run {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[FCM-W8] Legacy Push has no eventId; displaying non-actionable fallback",
            )
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W8",
                kind = VoiceNudgeContract.kindPush,
                groupId = data["groupId"],
                extras = mapOf("checkpoint" to "fcm_legacy_push_missing_event_id"),
            )
            showForegroundNotification(message, VoiceNudgeContract.kindPush)
            return
        }
        val groupId = data["groupId"] ?: run {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[FCM-W9] Legacy Push has no groupId; displaying non-actionable fallback",
            )
            VoiceNudgeDiagnostics.recordFcmHandlingFailure(
                worker = "W9",
                kind = VoiceNudgeContract.kindPush,
                eventId = eventId,
                extras = mapOf("checkpoint" to "fcm_legacy_push_missing_group_id"),
            )
            showForegroundNotification(message, VoiceNudgeContract.kindPush)
            return
        }
        val senderName = data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val groupName = data["groupName"]?.take(80).orEmpty()
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            manager.areNotificationsEnabled()
        } else {
            true
        }
        val channelImportance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.getNotificationChannel(
                VoiceNudgeContract.generalNotificationChannelId,
            )?.importance
        } else {
            null
        }
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-08A] Foreground display readiness " +
                "notificationsEnabled=$notificationsEnabled " +
                "channel=${VoiceNudgeContract.generalNotificationChannelId} " +
                "importance=${channelImportance ?: "legacy"}",
        )
        if (!notificationsEnabled) {
            VoiceNudgeDeliveryAck.reportFromFcmData(
                data,
                status = "failed",
                reason = "permission_denied_notifications",
            )
            return
        }
        try {
            val notificationId = VoiceNudgeNotifications.idFor(eventId)
            var acked = false
            fun ackPlayedOnce() {
                if (acked) return
                acked = true
                VoiceNudgeDeliveryAck.reportFromFcmData(
                    data,
                    status = "played",
                )
            }
            NotificationAvatarHelper.applyLargeIcon(
                this,
                data["senderPhotoUrl"],
                senderName,
                data["senderAvatarAsset"],
            ) { largeIcon ->
                try {
                    manager.notify(
                        notificationId,
                        VoiceNudgeNotifications.buildActionable(
                            this,
                            eventId,
                            groupId,
                            data["responseUrl"],
                            senderName,
                            "👋 $senderName nudged you${if (groupName.isBlank()) "" else " in $groupName"}",
                            "Accept or decline ✨",
                            largeIcon = largeIcon,
                            senderUserId = data["senderUserId"],
                        ),
                    )
                    ackPlayedOnce()
                } catch (error: SecurityException) {
                    VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
                    if (!acked) {
                        VoiceNudgeDeliveryAck.reportFromFcmData(
                            data,
                            status = "failed",
                            reason = "permission_denied_notifications",
                        )
                    }
                }
            }
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Actionable push notification displayed",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
            VoiceNudgeDeliveryAck.reportFromFcmData(
                data,
                status = "failed",
                reason = "permission_denied_notifications",
            )
        }
    }

    private fun showNudgeResponse(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: return
        val groupId = data["groupId"] ?: return
        val responseAction = data["responseAction"] ?: return
        val snoozeMinutes = data["snoozeMinutes"]?.toIntOrNull()
        val responderUserId = data["responderUserId"]
        val responderName = data["responderName"]?.take(80).orEmpty().ifBlank { "Your friend" }
        // B5: Nudge response arrived — cancel sender's expiry alarm.
        NudgeExpiryTracker.cancelExpiry(this, eventId)
        val flutterEngineAlive = NudgeActionDispatcher.isAttached()
        if (responseAction == "accept" && flutterEngineAlive) {
            queueSenderConnectOnAccept(eventId, groupId)
        }
        // Always forward to Flutter so the sender sheet / friend profiles can
        // show decline & snooze signifiers (and accept can clear pending state).
        NudgeResponseDispatcher.signal(
            mapOf(
                "eventId" to eventId,
                "groupId" to groupId,
                "responseAction" to responseAction,
                "responderUserId" to responderUserId,
                "responderName" to responderName,
                "snoozeMinutes" to snoozeMinutes?.toString(),
                "snoozedUntil" to data["snoozedUntil"],
            ),
        )
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        // When the sender's app is alive but backgrounded, Flutter connects
        // LiveKit in the background and posts a "you are online" notification
        // once the room is live — do not also show the generic response here.
        val showSystemResponse =
            responseAction != "accept" ||
                !flutterEngineAlive ||
                !DeviceLog.wasAppInBackground()
        if (showSystemResponse) {
            manager.notify(
                VoiceNudgeNotifications.idFor(eventId),
                VoiceNudgeNotifications.buildResponse(
                    this,
                    eventId,
                    groupId,
                    responderName,
                    responseAction,
                    snoozeMinutes,
                    senderProcessKilled =
                        responseAction == "accept" && !flutterEngineAlive,
                ),
            )
        }
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-ACTION-03] sender received response=$responseAction " +
                "snoozeMinutes=${snoozeMinutes ?: "none"} " +
                "flutterAlive=$flutterEngineAlive",
        )
    }

    private fun queueSenderConnectOnAccept(eventId: String, groupId: String) {
        NudgeActionStore.save(
            this,
            PendingNudgeAction("connect", eventId, groupId),
        )
        NudgeActionDispatcher.signal()
        // Deliberately do NOT start MainActivity here. When the Flutter engine
        // is alive but backgrounded, Dart connects LiveKit in the background
        // (kept alive by the voice-session foreground service) and posts the
        // "you are online" notification itself once the room is live.
    }

    /**
     * Real-time delivery confirmation (#5): only meaningful while the
     * sender's send-nudge bottom sheet is open, so it's forwarded straight
     * to Flutter with no persistent notification of its own.
     */
    private fun forwardDeliveryResult(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: return
        val status = data["status"] ?: return
        // Delivery ("played") is not an accept — keep the 10-minute expiry alarm.
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-DELIVERY-02] sender received status=$status " +
                "eventSuffix=${eventId.takeLast(6)} reason=${data["reason"].orEmpty()}",
        )
        DeviceLog.info(
            "NudgeService",
            "Delivery result received status=$status eventId=$eventId " +
                "reason=${data["reason"] ?: "-"} attention=${data["attention"] ?: "-"} " +
                "recipientUserId=${data["recipientUserId"] ?: "-"} " +
                "recipientName=${data["recipientName"] ?: "-"}",
            groupId = data["groupId"],
        )
        NudgeDeliveryResultDispatcher.signal(
            mapOf(
                "eventId" to eventId,
                "groupId" to data["groupId"],
                "kind" to data["kind"],
                "status" to status,
                "reason" to data["reason"]?.takeIf { it.isNotBlank() },
                // Audibility concern for an otherwise-played nudge
                // (volume_muted / volume_low).
                "attention" to data["attention"]?.takeIf { it.isNotBlank() },
                "recipientUserId" to data["recipientUserId"],
                "recipientName" to data["recipientName"],
            ),
        )
    }

    private fun isExpired(rawExpiry: String?): Boolean {
        val expiresAtSeconds = rawExpiry?.toLongOrNull() ?: return true
        return System.currentTimeMillis() / 1000 >= expiresAtSeconds
    }

    /** B5: Schedule a 10-minute expiry alarm for a received nudge. */
    private fun scheduleNudgeExpiry(data: Map<String, String>) {
        val eventId = data["eventId"] ?: return
        val senderName = data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        // recipientUserId is optional — FCM used to omit the top-level field
        // (it only lived inside deliveryToken). Never bail on it.
        val recipientUserId = data["recipientUserId"]?.takeIf { it.isNotBlank() }
        val groupId = data["groupId"]
        val recipientName = data["recipientName"]
        val kind = data["type"] ?: data["kind"]
        val groupName = data["groupName"]
        val responseUrl = data["responseUrl"]

        var scheduleEventId = eventId
        var notificationId = VoiceNudgeNotifications.idFor(eventId)
        var deadlineAtMs: Long? = null
        var memberEventIds = emptyList<String>()

        if (kind == VoiceNudgeContract.kindRing && !groupId.isNullOrBlank()) {
            val batch = RingNudgeBatchStore.remember(
                this,
                groupId = groupId,
                eventId = eventId,
                responseUrl = responseUrl,
                senderName = senderName,
            )
            scheduleEventId = batch.expiryKey
            notificationId = batch.notificationId
            deadlineAtMs = batch.startedAtMs + RingNudgeBatchStore.windowMs
            memberEventIds = batch.eventIds
            // Cancel any prior per-event alarm; the batch key owns the window.
            NudgeExpiryTracker.cancelExpiry(this, eventId)
        }

        NudgeExpiryTracker.scheduleExpiry(
            this,
            scheduleEventId,
            senderName,
            recipientUserId,
            groupId,
            recipientName,
            kind = kind,
            notificationId = notificationId,
            groupName = groupName,
            deadlineAtMs = deadlineAtMs,
            memberEventIds = memberEventIds,
        )
    }

    private fun recordIncomingNudge(data: Map<String, String>) {
        val eventId = data["eventId"]?.takeIf { it.isNotBlank() } ?: return
        val groupId = data["groupId"]?.takeIf { it.isNotBlank() } ?: return
        val senderUserId = data["senderUserId"]
        val senderName = data["senderName"]?.take(80)
        val kind = data["type"] ?: data["kind"]
        IncomingNudgeStore.upsert(
            this,
            eventId,
            groupId,
            senderUserId,
            senderName,
            responseUrl = data["responseUrl"],
            kind = kind,
        )
        DuoWidgetRenderer.updateAll(this)
        IncomingNudgeDispatcher.signal(
            buildMap {
                put("eventId", eventId)
                put("groupId", groupId)
                put("arrivedAtMs", System.currentTimeMillis())
                put("status", "pending")
                if (!senderUserId.isNullOrBlank()) put("senderUserId", senderUserId)
                if (!senderName.isNullOrBlank()) put("senderName", senderName)
                if (!kind.isNullOrBlank()) put("kind", kind)
            },
        )
    }
}

private fun nudgeUndeliveredReason(error: Throwable): String {
    return when {
        error is SecurityException -> "permission denied"
        error.message?.contains("Unable to resolve", ignoreCase = true) == true -> "network error"
        error.message?.contains("timeout", ignoreCase = true) == true -> "network error"
        error.message?.contains("UnknownHost", ignoreCase = true) == true -> "network error"
        else -> "unknown"
    }
}
