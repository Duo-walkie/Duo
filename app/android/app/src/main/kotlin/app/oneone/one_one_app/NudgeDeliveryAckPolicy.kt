package app.oneone.one_one_app

/**
 * Pure delivery-ACK helpers. Kept Android-free so they can be checked without
 * Robolectric. The 7s sender window was losing first-nudge confirmations:
 * cold FCM + first ExoPlayer init (~2.5s) + RTDB connect often exceeded it,
 * while the consecutive nudge (warm process) succeeded.
 */
internal object NudgeDeliveryAckPolicy {
    const val maxAttempts = 6
    const val maxPendingAgeMs = 10 * 60 * 1000L

    fun retryDelayMs(attempt: Int): Long = when (attempt.coerceAtLeast(0)) {
        0 -> 0L
        1 -> 400L
        2 -> 1_000L
        3 -> 2_500L
        4 -> 5_000L
        else -> 10_000L
    }

    /**
     * Path key for `userNudgeDeliveries/{sender}/{event}/{recipient}`.
     * Auth uid wins (RTDB rules require `auth.uid == recipient`). Fall back to
     * DeviceLog / FCM payload when Auth has not restored yet so we can persist
     * the ACK and flush once Auth is ready.
     */
    fun resolveRecipientUserId(
        authUid: String?,
        deviceLogUid: String?,
        payloadUid: String?,
    ): String? {
        fun clean(value: String?): String? {
            val trimmed = value?.trim().orEmpty()
            if (trimmed.isEmpty() || trimmed == "-") return null
            return trimmed
        }
        return clean(authUid) ?: clean(deviceLogUid) ?: clean(payloadUid)
    }

    /** Writes are rejected by rules until Auth is restored. */
    fun canAttemptWrite(authUid: String?, recipientUserId: String?): Boolean {
        val auth = authUid?.trim().orEmpty()
        val recipient = recipientUserId?.trim().orEmpty()
        return auth.isNotEmpty() && auth == recipient
    }

    fun isPendingAckFresh(queuedAtMs: Long, nowMs: Long): Boolean {
        if (queuedAtMs <= 0L) return false
        val age = nowMs - queuedAtMs
        return age in 0 until maxPendingAgeMs
    }

    /** A real played ACK must never be replaced by a later failed/timeout. */
    fun shouldOverwrite(existingStatus: String?, incomingStatus: String): Boolean {
        if (incomingStatus != "played" && incomingStatus != "failed") return false
        if (existingStatus == "played" && incomingStatus != "played") return false
        return true
    }
}
