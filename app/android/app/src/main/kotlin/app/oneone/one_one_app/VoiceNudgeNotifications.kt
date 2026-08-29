package app.oneone.one_one_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import androidx.core.graphics.drawable.IconCompat

object VoiceNudgeNotifications {
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(VoiceNudgeContract.notificationChannelId) == null) {
            val channel = NotificationChannel(
                VoiceNudgeContract.notificationChannelId,
                VoiceNudgeContract.notificationChannelName,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Urgent rings and short voice messages from your groups"
                enableVibration(true)
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(channel)
        }
        if (
            manager.getNotificationChannel(VoiceNudgeContract.generalNotificationChannelId) == null
        ) {
            val channel = NotificationChannel(
                VoiceNudgeContract.generalNotificationChannelId,
                VoiceNudgeContract.generalNotificationChannelName,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Nudges and activity from your Duo groups"
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(channel)
        }
    }

    /** Mic glyph — used only for ring / voice / push nudge notifications. */
    private val nudgeSmallIcon = R.drawable.ic_voice_nudge

    /**
     * Status-bar / title-row small icon. Android only draws the alpha of
     * this asset (white silhouette), generated from [assets/logo.png].
     */
    private val appSmallIcon = R.drawable.ic_notification_app

    fun build(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        status: String,
        ongoing: Boolean,
        cachedAudioAvailable: Boolean = false,
        isPlaying: Boolean = false,
        largeIcon: Bitmap? = null,
        senderUserId: String? = null,
        groupName: String? = null,
        notificationId: Int? = null,
        timeoutAfterMs: Long? = null,
    ): Notification {
        ensureChannels(context)
        val resolvedNotificationId = notificationId ?: idFor(eventId)
        val openIntent = openNudgeIntent(
            context,
            eventId,
            groupId,
            senderUserId,
            resolvedNotificationId,
        )
        val contentIntent = BrandedSplashIntents.mainActivity(
            context,
            requestCode(eventId, "open"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val configured = builder
            .setSmallIcon(nudgeSmallIcon)
            .setContentTitle(
                "🎙️ $senderName nudged you" +
                    if (groupName.isNullOrBlank()) "" else " in $groupName",
            )
            .setContentText(
                sanitizeNotificationCopy(status, FCM_USER_DELIVERY_FAILURE),
            )
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
        if (largeIcon != null) {
            configured.setLargeIcon(largeIcon)
        }
        if (
            !ongoing &&
            timeoutAfterMs != null &&
            timeoutAfterMs > 0L &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            configured.setTimeoutAfter(timeoutAfterMs)
        }
        configured.addNudgeActions(
            context = context,
            eventId = eventId,
            groupId = groupId,
            responseUrl = responseUrl,
            senderName = senderName,
            notificationId = resolvedNotificationId,
        )
        if (cachedAudioAvailable) {
            configured
                .addAction(
                    Notification.Action.Builder(
                        if (isPlaying) {
                            android.R.drawable.ic_media_pause
                        } else {
                            android.R.drawable.ic_media_play
                        },
                        if (isPlaying) "Pause" else "Play",
                        playbackIntent(
                            context,
                            eventId,
                            groupId,
                            responseUrl,
                            senderName,
                            groupName,
                            isPlaying,
                        ),
                    ).build(),
                )
                .setDeleteIntent(cacheDeleteIntent(context, eventId))
        }
        return configured.build()
    }

    fun buildActionable(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        title: String,
        body: String,
        largeIcon: Bitmap? = null,
        senderUserId: String? = null,
    ): Notification {
        ensureChannels(context)
        val notificationId = idFor(eventId)
        val openIntent = openNudgeIntent(
            context,
            eventId,
            groupId,
            senderUserId,
            notificationId,
        )
        val contentIntent = BrandedSplashIntents.mainActivity(
            context,
            requestCode(eventId, "open"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val configured = builder
            .setSmallIcon(nudgeSmallIcon)
            .setContentTitle(sanitizeNotificationCopy(title, "Duo"))
            .setContentText(
                sanitizeNotificationCopy(body, FCM_USER_DELIVERY_FAILURE),
            )
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setAutoCancel(true)
        if (largeIcon != null) {
            configured.setLargeIcon(largeIcon)
        }
        return configured
            .addNudgeActions(
                context = context,
                eventId = eventId,
                groupId = groupId,
                responseUrl = responseUrl,
                senderName = senderName,
            )
            .build()
    }

    fun buildResponse(
        context: Context,
        eventId: String,
        groupId: String,
        responderName: String,
        responseAction: String,
        snoozeMinutes: Int? = null,
        senderProcessKilled: Boolean = false,
    ): Notification {
        ensureChannels(context)
        val accepted = responseAction == "accept"
        val body = when {
            accepted && senderProcessKilled -> "Tap to go online 🟢"
            responseAction == "accept" -> "Tap to join together 🤝"
            responseAction == "snooze" ->
                "They asked you to wait ${snoozeMinutes ?: 5} minutes ⏳"
            else -> "They can’t join right now 💤"
        }
        val title = if (accepted && senderProcessKilled) {
            "💬 $responderName accepted your nudge"
        } else {
            "💬 $responderName answered your nudge"
        }
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (accepted) {
                action = VoiceNudgeContract.actionConnect
                putExtra(VoiceNudgeContract.extraEventId, eventId)
                putExtra(VoiceNudgeContract.extraGroupId, groupId)
                putExtra(VoiceNudgeContract.extraNotificationId, idFor(eventId))
            }
        }
        val contentIntent = BrandedSplashIntents.mainActivity(
            context,
            requestCode(eventId, "response"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(appSmallIcon)
            .setLargeIcon(NotificationAvatarHelper.appLogoBitmap(context))
            .setContentTitle(title)
            .setContentText(body)
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_SOCIAL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setAutoCancel(true)
            .build()
    }

    fun buildGeneral(
        context: Context,
        title: String,
        body: String,
        groupId: String? = null,
    ): Notification {
        ensureChannels(context)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = BrandedSplashIntents.mainActivity(
            context,
            7002,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        if (groupId != null) builder.setGroup(groupKey(groupId))
        return builder
            .setSmallIcon(appSmallIcon)
            .setLargeIcon(NotificationAvatarHelper.appLogoBitmap(context))
            .setContentTitle(sanitizeNotificationCopy(title, "Duo"))
            .setContentText(
                sanitizeNotificationCopy(body, FCM_USER_DELIVERY_FAILURE),
            )
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_SOCIAL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
    }

    /**
     * WhatsApp-style conversation: one shade notification per group that lists
     * each message separately (MessagingStyle) and supports inline reply.
     */
    fun buildChatConversation(
        context: Context,
        conversation: ChatConversation,
        largeIconOverride: Bitmap? = null,
    ): Notification {
        ensureChannels(context)
        val groupId = conversation.groupId
        val openIntent = Intent(context, MainActivity::class.java).apply {
            action = VoiceNudgeContract.actionOpenChatPile
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(VoiceNudgeContract.extraGroupId, groupId)
        }
        val contentIntent = BrandedSplashIntents.mainActivity(
            context,
            requestCode("chat_$groupId", "open"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val latest = conversation.messages.lastOrNull()
        val preview = if (latest == null) {
            conversation.groupName
        } else {
            "${latest.senderName}: ${latest.text}"
        }
        val latestIncoming = conversation.messages.lastOrNull { !it.fromSelf }
        val iconLine = latestIncoming ?: conversation.messages.lastOrNull()
        val largeIcon = largeIconOverride ?: if (iconLine != null) {
            NotificationAvatarHelper.largeIcon(
                context,
                iconLine.senderPhotoUrl,
                iconLine.senderName,
                iconLine.senderAvatarAsset,
            )
        } else {
            NotificationAvatarHelper.appLogoBitmap(context)
        }
        val configured = builder
            .setSmallIcon(appSmallIcon)
            .setLargeIcon(largeIcon)
            .setContentTitle(sanitizeNotificationCopy(conversation.groupName, "Duo"))
            .setContentText(sanitizeNotificationCopy(preview, FCM_USER_DELIVERY_FAILURE))
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
        applyChatMessagingStyle(configured, context, conversation)
        addChatReplyAction(configured, context, conversation)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            configured.setTimeoutAfter(ChatPileStore.ttlMs)
        }
        return configured.build()
    }

    private fun applyChatMessagingStyle(
        builder: Notification.Builder,
        context: Context,
        conversation: ChatConversation,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            val body = conversation.messages.joinToString("\n") { line ->
                val name = if (line.fromSelf) "You" else line.senderName
                "$name: ${line.text}"
            }
            builder.setStyle(
                Notification.BigTextStyle().bigText(
                    sanitizeNotificationCopy(body, FCM_USER_DELIVERY_FAILURE),
                ),
            )
            return
        }
        val localLine = conversation.messages.lastOrNull { it.fromSelf }
        val style = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val userBitmap = if (localLine != null) {
                NotificationAvatarHelper.largeIcon(
                    context,
                    localLine.senderPhotoUrl,
                    localLine.senderName,
                    localLine.senderAvatarAsset,
                )
            } else {
                NotificationAvatarHelper.appLogoBitmap(context)
            }
            val user = Person.Builder()
                .setName("You")
                .setIcon(IconCompat.createWithBitmap(userBitmap).toIcon())
                .build()
            Notification.MessagingStyle(user)
                .setConversationTitle(conversation.groupName)
                .setGroupConversation(true)
        } else {
            @Suppress("DEPRECATION")
            Notification.MessagingStyle("You")
                .setConversationTitle(conversation.groupName)
                .setGroupConversation(true)
        }
        for (line in conversation.messages) {
            val text = sanitizeNotificationCopy(line.text, FCM_USER_DELIVERY_FAILURE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val senderBitmap = NotificationAvatarHelper.largeIcon(
                    context,
                    line.senderPhotoUrl,
                    line.senderName,
                    line.senderAvatarAsset,
                )
                val sender = Person.Builder()
                    .setName(if (line.fromSelf) "You" else line.senderName)
                    .setKey(line.senderUserId.ifBlank { line.senderName })
                    .setIcon(IconCompat.createWithBitmap(senderBitmap).toIcon())
                    .build()
                style.addMessage(
                    Notification.MessagingStyle.Message(text, line.timestampMs, sender),
                )
            } else {
                @Suppress("DEPRECATION")
                style.addMessage(
                    text,
                    line.timestampMs,
                    if (line.fromSelf) "You" else line.senderName,
                )
            }
        }
        builder.setStyle(style)
    }

    private fun addChatReplyAction(
        builder: Notification.Builder,
        context: Context,
        conversation: ChatConversation,
    ) {
        val replyFlags = PendingIntent.FLAG_UPDATE_CURRENT or if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        ) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val replyIntent = Intent(context, ChatReplyReceiver::class.java).apply {
            action = VoiceNudgeContract.actionReplyChat
            putExtra(VoiceNudgeContract.extraGroupId, conversation.groupId)
            putExtra(VoiceNudgeContract.extraGroupName, conversation.groupName)
            putExtra(VoiceNudgeContract.extraNotifyUrl, conversation.notifyUrl)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode(conversation.groupId, "chat_reply"),
            replyIntent,
            replyFlags,
        )
        val remoteInput = RemoteInput.Builder(VoiceNudgeContract.extraChatReply)
            .setLabel("Reply")
            .setAllowFreeFormInput(true)
            .build()
        builder.addAction(
            Notification.Action.Builder(0, "Reply", replyPendingIntent)
                .addRemoteInput(remoteInput)
                .build(),
        )
    }

    fun chatPileId(groupId: String): Int = idFor("chat_pile_$groupId")

    fun cancelChatPile(context: Context, groupId: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(chatPileId(groupId))
        ChatPileStore.reset(context, groupId)
    }

    fun refreshChatConversation(context: Context, groupId: String) {
        val conversation = ChatPileStore.conversation(context, groupId) ?: return
        val manager = context.getSystemService(NotificationManager::class.java)
        val latestIncoming = conversation.messages.lastOrNull { !it.fromSelf }
        val iconLine = latestIncoming ?: conversation.messages.lastOrNull()
        if (iconLine == null) {
            manager.notify(chatPileId(groupId), buildChatConversation(context, conversation))
            return
        }
        NotificationAvatarHelper.applyLargeIcon(
            context,
            iconLine.senderPhotoUrl,
            iconLine.senderName,
            iconLine.senderAvatarAsset,
        ) { bitmap ->
            manager.notify(
                chatPileId(groupId),
                buildChatConversation(context, conversation, largeIconOverride = bitmap),
            )
        }
    }

    /** Drops shade piles whose bubbles have already vanished. */
    fun cancelStaleChatPiles(context: Context) {
        for (groupId in ChatPileStore.staleGroupIds(context)) {
            cancelChatPile(context, groupId)
        }
    }

    fun idFor(eventId: String): Int = eventId.hashCode() and 0x7fffffff

    fun groupKey(groupId: String): String = "oneone_group_$groupId"

    private fun Notification.Builder.addNudgeActions(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        notificationId: Int = idFor(eventId),
    ): Notification.Builder {
        if (responseUrl.isNullOrBlank()) return this
        val acceptPendingIntent = BrandedSplashIntents.mainActivity(
            context,
            requestCode(eventId, "accept"),
            acceptIntent(context, eventId, groupId, notificationId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val declinePendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode(eventId, "decline"),
            responseIntent(
                context,
                VoiceNudgeContract.actionDecline,
                eventId,
                responseUrl,
                senderName,
                notificationId,
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return addAction(Notification.Action.Builder(0, "Accept", acceptPendingIntent).build())
            .addAction(Notification.Action.Builder(0, "Decline", declinePendingIntent).build())
    }

    private fun acceptIntent(
        context: Context,
        eventId: String,
        groupId: String,
        notificationId: Int,
    ) = Intent(context, MainActivity::class.java).apply {
        action = VoiceNudgeContract.actionAccept
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(VoiceNudgeContract.extraEventId, eventId)
        putExtra(VoiceNudgeContract.extraGroupId, groupId)
        putExtra(VoiceNudgeContract.extraNotificationId, notificationId)
    }

    private fun openNudgeIntent(
        context: Context,
        eventId: String,
        groupId: String,
        senderUserId: String?,
        notificationId: Int,
    ) = Intent(context, MainActivity::class.java).apply {
        action = VoiceNudgeContract.actionOpenNudge
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(VoiceNudgeContract.extraEventId, eventId)
        putExtra(VoiceNudgeContract.extraGroupId, groupId)
        putExtra(VoiceNudgeContract.extraNotificationId, notificationId)
        if (!senderUserId.isNullOrBlank()) {
            putExtra(VoiceNudgeContract.extraSenderUserId, senderUserId)
        }
    }

    private fun responseIntent(
        context: Context,
        actionName: String,
        eventId: String,
        responseUrl: String,
        senderName: String,
        notificationId: Int,
    ) = Intent(context, NudgeNotificationActionReceiver::class.java).apply {
        action = actionName
        putExtra(VoiceNudgeContract.extraEventId, eventId)
        putExtra(VoiceNudgeContract.extraResponseUrl, responseUrl)
        putExtra(VoiceNudgeContract.extraSenderName, senderName)
        putExtra(VoiceNudgeContract.extraNotificationId, notificationId)
    }

    private fun playbackIntent(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        groupName: String?,
        isPlaying: Boolean,
    ): PendingIntent {
        val action = if (isPlaying) {
            VoiceNudgeContract.actionPauseCachedAudio
        } else {
            VoiceNudgeContract.actionPlayCachedAudio
        }
        val intent = Intent(context, VoiceNudgePlaybackService::class.java).apply {
            this.action = action
            putExtra(VoiceNudgeContract.extraKind, VoiceNudgeContract.kindVoice)
            putExtra(VoiceNudgeContract.extraEventId, eventId)
            putExtra(VoiceNudgeContract.extraGroupId, groupId)
            putExtra(VoiceNudgeContract.extraResponseUrl, responseUrl)
            putExtra(VoiceNudgeContract.extraSenderName, senderName)
            putExtra(VoiceNudgeContract.extraGroupName, groupName)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return if (
            !isPlaying &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            PendingIntent.getForegroundService(
                context,
                requestCode(eventId, action),
                intent,
                flags,
            )
        } else {
            PendingIntent.getService(
                context,
                requestCode(eventId, action),
                intent,
                flags,
            )
        }
    }

    private fun cacheDeleteIntent(context: Context, eventId: String): PendingIntent {
        val intent = Intent(context, VoiceNudgeCacheDismissReceiver::class.java).apply {
            action = VoiceNudgeContract.actionDismissCachedAudio
            putExtra(VoiceNudgeContract.extraEventId, eventId)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode(eventId, "dismiss_audio"),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun requestCode(eventId: String, action: String): Int =
        "$eventId:$action".hashCode() and 0x7fffffff
}

data class ChatLine(
    val messageId: String,
    val senderUserId: String,
    val senderName: String,
    val text: String,
    val timestampMs: Long,
    val fromSelf: Boolean = false,
    val senderPhotoUrl: String? = null,
    val senderAvatarAsset: String? = null,
)

data class ChatConversation(
    val groupId: String,
    val groupName: String,
    val notifyUrl: String?,
    val messages: List<ChatLine>,
)

object ChatPileStore {
    private const val prefsName = "one_one_chat_pile"
    private const val openedPrefsName = "one_one_chat_pile_opened"
    private const val openedGroupIdKey = "group_id"
    private const val messagesSuffix = "_msgs"
    private const val nameSuffix = "_name"
    private const val notifySuffix = "_notify"
    private const val atSuffix = "_at"

    /** Matches Flutter `ChatMessageRepository.visibleLimit`. */
    const val maxCount = 5

    /** Matches Flutter lifetime + fade (10 + 2 minutes). */
    const val ttlMs = 12 * 60 * 1000L

    fun append(
        context: Context,
        groupId: String,
        groupName: String,
        messageId: String,
        senderUserId: String,
        senderName: String,
        text: String,
        notifyUrl: String?,
        fromSelf: Boolean = false,
        senderPhotoUrl: String? = null,
        senderAvatarAsset: String? = null,
        timestampMs: Long = System.currentTimeMillis(),
    ) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val existing = conversation(context, groupId)?.messages.orEmpty()
        if (existing.any { it.messageId == messageId }) return
        val next = (existing + ChatLine(
            messageId = messageId,
            senderUserId = senderUserId,
            senderName = senderName,
            text = text,
            timestampMs = timestampMs,
            fromSelf = fromSelf,
            senderPhotoUrl = senderPhotoUrl?.trim()?.takeIf { it.isNotEmpty() },
            senderAvatarAsset = senderAvatarAsset?.trim()?.takeIf { it.isNotEmpty() },
        )).takeLast(maxCount)
        prefs.edit()
            .putString(groupId + messagesSuffix, encodeMessages(next))
            .putString(groupId + nameSuffix, groupName)
            .putString(groupId + notifySuffix, notifyUrl)
            .putLong(groupId + atSuffix, timestampMs)
            .apply()
    }

    fun conversation(context: Context, groupId: String): ChatConversation? {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val lastAt = prefs.getLong(groupId + atSuffix, 0L)
        if (lastAt <= 0L || System.currentTimeMillis() - lastAt >= ttlMs) {
            return null
        }
        val messages = decodeMessages(prefs.getString(groupId + messagesSuffix, null))
        if (messages.isEmpty()) return null
        return ChatConversation(
            groupId = groupId,
            groupName = prefs.getString(groupId + nameSuffix, null)?.ifBlank { null } ?: "Duo",
            notifyUrl = prefs.getString(groupId + notifySuffix, null),
            messages = messages,
        )
    }

    fun reset(context: Context, groupId: String) {
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .remove(groupId)
            .remove(groupId + atSuffix)
            .remove(groupId + messagesSuffix)
            .remove(groupId + nameSuffix)
            .remove(groupId + notifySuffix)
            .apply()
    }

    fun staleGroupIds(context: Context): List<String> {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val groupIds = prefs.all.keys.mapNotNull { key ->
            when {
                key.endsWith(atSuffix) -> key.removeSuffix(atSuffix)
                key.endsWith(messagesSuffix) -> key.removeSuffix(messagesSuffix)
                key.endsWith(nameSuffix) -> key.removeSuffix(nameSuffix)
                key.endsWith(notifySuffix) -> key.removeSuffix(notifySuffix)
                else -> key
            }
        }.filter { it.isNotBlank() }.toSet()
        return groupIds.filter { groupId ->
            val lastAt = prefs.getLong(groupId + atSuffix, 0L)
            lastAt <= 0L || now - lastAt >= ttlMs
        }
    }

    fun markOpened(context: Context, groupId: String) {
        context.getSharedPreferences(openedPrefsName, Context.MODE_PRIVATE)
            .edit()
            .putString(openedGroupIdKey, groupId)
            .apply()
    }

    fun takeOpened(context: Context): String? {
        val prefs = context.getSharedPreferences(openedPrefsName, Context.MODE_PRIVATE)
        val groupId = prefs.getString(openedGroupIdKey, null)?.takeIf { it.isNotBlank() }
        if (groupId != null) prefs.edit().remove(openedGroupIdKey).apply()
        return groupId
    }

    private fun encodeMessages(messages: List<ChatLine>): String {
        val array = org.json.JSONArray()
        for (line in messages) {
            array.put(
                org.json.JSONObject().apply {
                    put("messageId", line.messageId)
                    put("senderUserId", line.senderUserId)
                    put("senderName", line.senderName)
                    put("text", line.text)
                    put("timestampMs", line.timestampMs)
                    put("fromSelf", line.fromSelf)
                    line.senderPhotoUrl?.let { put("senderPhotoUrl", it) }
                    line.senderAvatarAsset?.let { put("senderAvatarAsset", it) }
                },
            )
        }
        return array.toString()
    }

    private fun decodeMessages(raw: String?): List<ChatLine> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            val array = org.json.JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val obj = array.optJSONObject(index) ?: continue
                    val text = obj.optString("text").trim()
                    val messageId = obj.optString("messageId").trim()
                    if (text.isEmpty() || messageId.isEmpty()) continue
                    add(
                        ChatLine(
                            messageId = messageId,
                            senderUserId = obj.optString("senderUserId"),
                            senderName = obj.optString("senderName").ifBlank { "Someone" },
                            text = text,
                            timestampMs = obj.optLong("timestampMs", System.currentTimeMillis()),
                            fromSelf = obj.optBoolean("fromSelf", false),
                            senderPhotoUrl = obj.optString("senderPhotoUrl")
                                .trim()
                                .takeIf { it.isNotEmpty() },
                            senderAvatarAsset = obj.optString("senderAvatarAsset")
                                .trim()
                                .takeIf { it.isNotEmpty() },
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }
}
