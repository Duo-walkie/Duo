package app.oneone.one_one_app

import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * WhatsApp-style inline reply: writes a 10-word chat bubble to RTDB from the
 * notification shade, then fans the same bubble out over FCM.
 */
class ChatReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != VoiceNudgeContract.actionReplyChat) return
        val groupId = intent.getStringExtra(VoiceNudgeContract.extraGroupId)
            ?.takeIf { it.isNotBlank() } ?: return
        val groupName = intent.getStringExtra(VoiceNudgeContract.extraGroupName)
            ?.takeIf { it.isNotBlank() } ?: "Duo"
        val notifyUrl = intent.getStringExtra(VoiceNudgeContract.extraNotifyUrl)
        val raw = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(VoiceNudgeContract.extraChatReply)
            ?.toString()
            ?: return
        val text = sanitizeChatReply(raw) ?: return
        val pending = goAsync()
        val appContext = context.applicationContext
        Thread {
            try {
                postReply(
                    appContext = appContext,
                    groupId = groupId,
                    groupName = groupName,
                    notifyUrl = notifyUrl,
                    text = text,
                )
            } catch (error: Exception) {
                VoiceNudgeDiagnostics.logFailure("[CHAT-REPLY] Inline reply failed", error)
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun postReply(
        appContext: Context,
        groupId: String,
        groupName: String,
        notifyUrl: String?,
        text: String,
    ) {
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[CHAT-REPLY] No signed-in user; dropping reply")
            return
        }
        val displayName = user.displayName?.trim()?.takeUnless { it.isEmpty() }
            ?: readDisplayName(user.uid)
            ?: "You"
        val ref = FirebaseDatabase.getInstance()
            .getReference("groupMessages/$groupId")
            .push()
        val messageId = ref.key
        if (messageId.isNullOrBlank()) {
            Log.w(VoiceNudgeDiagnostics.tag, "[CHAT-REPLY] Failed to allocate message id")
            return
        }
        val nowSeconds = System.currentTimeMillis() / 1000L
        val payload = mapOf(
            "messageId" to messageId,
            "groupId" to groupId,
            "senderUserId" to user.uid,
            "senderDisplayName" to displayName,
            "text" to text,
            "createdAt" to nowSeconds,
            "expiresAt" to nowSeconds + ChatPileStore.ttlMs / 1000L,
        )
        Tasks.await(ref.setValue(payload), 8, TimeUnit.SECONDS)
        val profile = readProfileFields(user.uid)
        ChatPileStore.append(
            appContext,
            groupId = groupId,
            groupName = groupName,
            messageId = messageId,
            senderUserId = user.uid,
            senderName = displayName,
            text = text,
            notifyUrl = notifyUrl,
            fromSelf = true,
            senderPhotoUrl = profile?.photoUrl,
            senderAvatarAsset = profile?.avatarAsset,
        )
        VoiceNudgeNotifications.refreshChatConversation(appContext, groupId)
        if (!notifyUrl.isNullOrBlank()) {
            val idToken = Tasks.await(user.getIdToken(false), 8, TimeUnit.SECONDS).token
            postNotify(notifyUrl, idToken, messageId, text)
        }
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[CHAT-REPLY] Posted inline reply groupSuffix=${groupId.takeLast(6)}",
        )
    }

    private fun readDisplayName(userId: String): String? {
        return try {
            val snapshot = Tasks.await(
                FirebaseDatabase.getInstance()
                    .getReference("users/$userId/displayName")
                    .get(),
                5,
                TimeUnit.SECONDS,
            )
            snapshot.getValue(String::class.java)?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    private data class ProfileFields(
        val photoUrl: String?,
        val avatarAsset: String?,
    )

    private fun readProfileFields(userId: String): ProfileFields? {
        return try {
            val snapshot = Tasks.await(
                FirebaseDatabase.getInstance()
                    .getReference("users/$userId")
                    .get(),
                5,
                TimeUnit.SECONDS,
            )
            val data = snapshot.value as? Map<*, *> ?: return null
            val photoUrl = data["profilePhotoUrl"]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            val avatarAsset = data["avatarAsset"]?.toString()?.trim()?.takeIf { path ->
                NotificationAvatarHelper.isBundledAvatarPath(path)
            }
            ProfileFields(photoUrl = photoUrl, avatarAsset = avatarAsset)
        } catch (_: Exception) {
            null
        }
    }

    private fun postNotify(notifyUrl: String, idToken: String?, messageId: String, text: String) {
        if (idToken.isNullOrBlank()) return
        var connection: HttpURLConnection? = null
        try {
            val opened = URL(notifyUrl).openConnection() as HttpURLConnection
            connection = opened
            opened.connectTimeout = 8_000
            opened.readTimeout = 8_000
            opened.requestMethod = "POST"
            opened.doOutput = true
            opened.setRequestProperty("content-type", "application/json")
            opened.setRequestProperty("authorization", "Bearer $idToken")
            val body = JSONObject()
                .put("messageId", messageId)
                .put("text", text)
                .toString()
            opened.outputStream.use { it.write(body.toByteArray()) }
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[CHAT-REPLY] Notify HTTP=${opened.responseCode}",
            )
        } catch (error: Exception) {
            VoiceNudgeDiagnostics.logFailure("[CHAT-REPLY] Notify fan-out", error)
        } finally {
            connection?.disconnect()
        }
    }

    companion object {
        private const val maxWords = 10

        fun sanitizeChatReply(raw: String): String? {
            val normalized = raw.trim().replace(Regex("\\s+"), " ")
            if (normalized.isEmpty()) return null
            val words = normalized.split(" ")
            return words.take(maxWords).joinToString(" ").take(240)
        }
    }
}
