package app.oneone.one_one_app

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.android.installreferrer.api.ReferrerDetails
import java.net.URLDecoder

/**
 * Reads the Play Install Referrer on first launch to recover an invite code
 * that was embedded in the Play Store link the user followed.
 *
 * Flow:
 *  1. Inviting user shares https://one-one-xw00.onrender.com/invite/<CODE>
 *  2. Recipient (no app) taps it → landing page sends them to Play Store with
 *     ?referrer=inviteCode%3D<CODE>
 *  3. Play Store records the referrer and delivers it on first app launch.
 *  4. This reader parses the referrer, saves the code via InviteLinkContract,
 *     and the existing _joinPendingInvite() in StartupGateScreen picks it up.
 *
 * Safe to call on every cold start. The Play referrer is consumed once so a
 * later successful join cannot be resurrected on the next launch.
 */
object InstallReferrerReader {

    private const val TAG = "OneOneInviteReferrer"
    private const val INVITE_CODE_KEY = "inviteCode"
    private const val preferencesName = "one_one_invite_links"
    private const val referrerConsumedKey = "install_referrer_consumed"

    fun readOnce(context: Context, onCodeSaved: (() -> Unit)? = null) {
        val appContext = context.applicationContext
        val preferences = appContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        if (preferences.getBoolean(referrerConsumedKey, false)) return

        val client = InstallReferrerClient.newBuilder(appContext).build()
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                try {
                    if (responseCode != InstallReferrerClient.InstallReferrerResponse.OK) {
                        if (isTerminalReferrerResponse(responseCode)) {
                            markConsumed(preferences)
                        }
                        Log.d(TAG, "Install referrer not available (code=$responseCode)")
                        return
                    }
                    markConsumed(preferences)

                    // A live App Link / custom-scheme tap wins over the stale
                    // Play referrer from this install.
                    if (InviteLinkContract.peekPendingCode(appContext) != null) return

                    val details: ReferrerDetails = client.installReferrer
                    val rawReferrer = details.installReferrer ?: return
                    Log.d(TAG, "Raw install referrer: $rawReferrer")

                    // The referrer value is URL-encoded on the Play Store side.
                    // e.g. "inviteCode%3DABCDE" → "inviteCode=ABCDE"
                    val decoded = try {
                        URLDecoder.decode(rawReferrer, "UTF-8")
                    } catch (_: Exception) {
                        rawReferrer
                    }

                    // Parse key=value pairs separated by & (standard referrer format)
                    val params = decoded.split("&").mapNotNull { pair ->
                        val idx = pair.indexOf('=')
                        if (idx < 1) null else pair.substring(0, idx) to pair.substring(idx + 1)
                    }.toMap()

                    val inviteCode = params[INVITE_CODE_KEY]
                        ?.trim()
                        ?.uppercase()
                        ?.takeIf { it.matches(Regex("[A-Z0-9_-]{4,64}")) }
                        ?: return

                    Log.i(TAG, "Recovered invite code from referrer codeSuffix=${inviteCode.takeLast(4)}")
                    InviteLinkContract.savePendingCode(appContext, inviteCode)
                    Handler(Looper.getMainLooper()).post {
                        onCodeSaved?.invoke()
                    }
                } finally {
                    try { client.endConnection() } catch (_: Exception) {}
                }
            }

            override fun onInstallReferrerServiceDisconnected() {
                Log.d(TAG, "Install referrer service disconnected")
            }
        })
    }

    private fun isTerminalReferrerResponse(responseCode: Int): Boolean =
        responseCode == InstallReferrerClient.InstallReferrerResponse.FEATURE_NOT_SUPPORTED ||
            responseCode == InstallReferrerClient.InstallReferrerResponse.DEVELOPER_ERROR

    private fun markConsumed(preferences: SharedPreferences) {
        preferences.edit().putBoolean(referrerConsumedKey, true).apply()
    }
}
