package app.oneone.one_one_app

import android.content.Context
import com.google.android.gms.tasks.Tasks
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Result of a fire-and-forget widget action. */
sealed class DuoWidgetApiResult {
    data class Success(val body: JSONObject) : DuoWidgetApiResult()
    data class Failure(val message: String) : DuoWidgetApiResult()
}

/**
 * Minimal background HTTP client the widget/mic overlay use to call the
 * same nudge endpoints as the Flutter app, authenticated with the current
 * Firebase user's ID token. All calls are synchronous and must run off the
 * main thread (see [executor]).
 */
object DuoWidgetApi {
    private val executor = Executors.newCachedThreadPool()

    fun submit(block: () -> Unit) {
        executor.execute {
            try {
                block()
            } catch (error: Exception) {
                DuoWidgetLog.e("API-00", "Unhandled widget action error", error)
            }
        }
    }

    private fun idTokenBlocking(): String? {
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) {
            DuoWidgetLog.w("API-01", "no Firebase user — not_signed_in")
            return null
        }
        return try {
            // Force refresh so a stale token does not 401 widget sends.
            val task = user.getIdToken(true)
            Tasks.await(task, 12, TimeUnit.SECONDS)?.token.also { token ->
                if (token.isNullOrBlank()) {
                    DuoWidgetLog.w("API-02", "ID token blank")
                } else {
                    DuoWidgetLog.d("API-02", "ID token ok length=${token.length}")
                }
            }
        } catch (error: Exception) {
            DuoWidgetLog.e("API-03", "Failed to obtain ID token", error)
            null
        }
    }

    private fun postJson(
        url: String,
        body: JSONObject,
        idToken: String?,
    ): DuoWidgetApiResult {
        var connection: HttpURLConnection? = null
        return try {
            DuoWidgetLog.d("API-10", "POST $url bodyKeys=${body.keys().asSequence().toList()}")
            val opened = URL(url).openConnection() as HttpURLConnection
            connection = opened
            opened.connectTimeout = 15_000
            opened.readTimeout = 20_000
            opened.requestMethod = "POST"
            opened.doOutput = true
            opened.doInput = true
            opened.instanceFollowRedirects = true
            opened.setRequestProperty("content-type", "application/json")
            opened.setRequestProperty("accept", "application/json")
            if (!idToken.isNullOrBlank()) {
                opened.setRequestProperty("authorization", "Bearer $idToken")
            }
            val payload = body.toString().toByteArray(Charsets.UTF_8)
            opened.setFixedLengthStreamingMode(payload.size)
            opened.outputStream.use { it.write(payload) }
            val code = opened.responseCode
            val stream = if (code in 200..299) opened.inputStream else opened.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (code in 200..299) {
                val json = if (text.isBlank()) JSONObject() else JSONObject(text)
                DuoWidgetLog.i("API-11", "POST OK $code urlEnds=${url.takeLast(40)}")
                DuoWidgetApiResult.Success(json)
            } else {
                DuoWidgetLog.e(
                    "API-12",
                    "POST FAIL $code urlEnds=${url.takeLast(48)} body=${text.take(240)}",
                )
                DuoWidgetApiResult.Failure("HTTP $code ${text.take(160)}")
            }
        } catch (error: Exception) {
            DuoWidgetLog.e("API-13", "POST exception ${url.takeLast(48)}", error)
            DuoWidgetApiResult.Failure(error.message ?: "network_error")
        } finally {
            connection?.disconnect()
        }
    }

    private fun putBytes(
        url: String,
        bytes: ByteArray,
        headers: Map<String, String>,
    ): DuoWidgetApiResult {
        var connection: HttpURLConnection? = null
        return try {
            DuoWidgetLog.d(
                "API-20",
                "PUT bytes=${bytes.size} headers=${headers.keys} urlHost=${URL(url).host}",
            )
            val opened = URL(url).openConnection() as HttpURLConnection
            connection = opened
            opened.connectTimeout = 20_000
            opened.readTimeout = 30_000
            // Signed GCS URLs must not be redirected by the client or the
            // signature breaks. Flutter's putBytesToUrl similarly treats the
            // upload URL as the final endpoint.
            opened.instanceFollowRedirects = false
            opened.doOutput = true
            opened.doInput = true
            opened.setRequestMethod("PUT")
            for ((key, value) in headers) {
                if (value.isNotBlank()) opened.setRequestProperty(key, value)
            }
            opened.setFixedLengthStreamingMode(bytes.size)
            opened.outputStream.use { out ->
                out.write(bytes)
                out.flush()
            }
            val code = opened.responseCode
            // GCS often returns 200 or 204.
            if (code in 200..299) {
                DuoWidgetLog.i("API-21", "PUT OK $code bytes=${bytes.size}")
                DuoWidgetApiResult.Success(JSONObject())
            } else {
                val err = try {
                    opened.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                } catch (_: Exception) {
                    ""
                }
                DuoWidgetLog.e("API-22", "PUT FAIL $code body=${err.take(240)}")
                DuoWidgetApiResult.Failure("upload_HTTP_$code ${err.take(120)}")
            }
        } catch (error: Exception) {
            DuoWidgetLog.e("API-23", "PUT exception", error)
            DuoWidgetApiResult.Failure(error.message ?: "upload_network_error")
        } finally {
            connection?.disconnect()
        }
    }

    fun sendPush(context: Context, groupId: String): DuoWidgetApiResult {
        val base = DuoWidgetSnapshotStore.apiBaseUrl(context)
        val token = idTokenBlocking() ?: return DuoWidgetApiResult.Failure("not_signed_in")
        val body = JSONObject().put("targetScope", "all_friends")
        return postJson("$base/v1/groups/$groupId/nudges", body, token)
    }

    fun sendRing(
        context: Context,
        groupId: String,
        durationSeconds: Int = 3,
    ): DuoWidgetApiResult {
        val base = DuoWidgetSnapshotStore.apiBaseUrl(context)
        val token = idTokenBlocking() ?: return DuoWidgetApiResult.Failure("not_signed_in")
        val body = JSONObject()
            .put("targetScope", "all_friends")
            .put("durationSeconds", durationSeconds)
        return postJson("$base/v1/groups/$groupId/ring-nudges", body, token)
    }

    fun respond(
        context: Context,
        responseUrl: String,
        action: String,
    ): DuoWidgetApiResult {
        val token = idTokenBlocking() ?: return DuoWidgetApiResult.Failure("not_signed_in")
        val body = JSONObject().put("action", action)
        return postJson(responseUrl, body, token)
    }

    /**
     * Full voice-nudge send flow: reserve a signed write URL, PUT the audio
     * bytes directly to storage, then complete so the backend fans out FCM.
     * Mirrors [NudgeRepository.sendVoice] on the Dart side.
     */
    fun sendVoice(
        context: Context,
        groupId: String,
        audioFile: File,
        durationMs: Long,
    ): DuoWidgetApiResult {
        DuoWidgetLog.i(
            "API-30",
            "sendVoice start groupSuffix=${groupId.takeLast(6)} " +
                "file=${audioFile.name} exists=${audioFile.exists()} " +
                "bytes=${audioFile.length()} durationMs=$durationMs",
        )
        if (!audioFile.exists() || audioFile.length() < 64L) {
            return DuoWidgetApiResult.Failure("audio_file_empty")
        }
        val base = DuoWidgetSnapshotStore.apiBaseUrl(context)
        val token = idTokenBlocking() ?: return DuoWidgetApiResult.Failure("not_signed_in")

        val initiateBody = JSONObject()
            .put("targetScope", "all_friends")
            .put("durationMs", durationMs)
        val initiated = postJson(
            "$base/v1/groups/$groupId/voice-nudges/uploads",
            initiateBody,
            token,
        )
        if (initiated !is DuoWidgetApiResult.Success) {
            DuoWidgetLog.e("API-31", "initiate upload failed: ${(initiated as DuoWidgetApiResult.Failure).message}")
            return initiated
        }
        val eventId = initiated.body.optString("notificationEventId", "")
        val uploadUrl = initiated.body.optString("uploadUrl", "")
        val uploadTicket = initiated.body.optString("uploadTicket", "")
        DuoWidgetLog.i(
            "API-32",
            "initiate OK eventSuffix=${eventId.takeLast(6)} " +
                "hasUploadUrl=${uploadUrl.isNotBlank()} hasTicket=${uploadTicket.isNotBlank()}",
        )
        if (eventId.isBlank() || uploadUrl.isBlank()) {
            return DuoWidgetApiResult.Failure("voice_nudge_upload_url_invalid")
        }
        val headers = mutableMapOf<String, String>()
        val requiredHeaders = initiated.body.optJSONObject("requiredHeaders")
        if (requiredHeaders != null) {
            val keys = requiredHeaders.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                headers[key] = requiredHeaders.optString(key, "")
            }
        }
        if (!headers.keys.any { it.equals("content-type", ignoreCase = true) }) {
            headers["content-type"] =
                initiated.body.optString("contentType", "audio/mp4")
        }

        val bytes = audioFile.readBytes()
        val uploadResult = putBytes(uploadUrl, bytes, headers)
        if (uploadResult !is DuoWidgetApiResult.Success) {
            DuoWidgetLog.e("API-33", "GCS put failed: ${(uploadResult as DuoWidgetApiResult.Failure).message}")
            return uploadResult
        }

        val completeBody = JSONObject()
        if (uploadTicket.isNotBlank()) {
            completeBody.put("uploadTicket", uploadTicket)
        } else {
            // Legacy path: backend wrote RTDB metadata during initiate when
            // recipientDevices/senderName were omitted. Empty body is OK.
            DuoWidgetLog.w("API-34", "no uploadTicket — using legacy complete {}")
        }
        val complete = postJson(
            "$base/v1/groups/$groupId/voice-nudges/$eventId/complete",
            completeBody,
            token,
        )
        when (complete) {
            is DuoWidgetApiResult.Success ->
                DuoWidgetLog.i(
                    "API-35",
                    "complete OK eventSuffix=${eventId.takeLast(6)} " +
                        "sent=${complete.body.opt("sent")} " +
                        "targetDevices=${complete.body.opt("targetDevices")}",
                )
            is DuoWidgetApiResult.Failure ->
                DuoWidgetLog.e("API-36", "complete failed: ${complete.message}")
        }
        return complete
    }
}
