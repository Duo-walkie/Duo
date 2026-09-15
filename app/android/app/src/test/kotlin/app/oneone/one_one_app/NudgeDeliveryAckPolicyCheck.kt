package app.oneone.one_one_app

fun main() {
    check(NudgeDeliveryAckPolicy.retryDelayMs(0) == 0L)
    check(NudgeDeliveryAckPolicy.retryDelayMs(1) == 400L)
    check(NudgeDeliveryAckPolicy.retryDelayMs(5) == 10_000L)
    check(NudgeDeliveryAckPolicy.retryDelayMs(-1) == 0L)

    check(
        NudgeDeliveryAckPolicy.resolveRecipientUserId(
            authUid = "auth",
            deviceLogUid = "log",
            payloadUid = "payload",
        ) == "auth",
    )
    check(
        NudgeDeliveryAckPolicy.resolveRecipientUserId(
            authUid = null,
            deviceLogUid = "-",
            payloadUid = " payload ",
        ) == "payload",
    )
    check(
        NudgeDeliveryAckPolicy.resolveRecipientUserId(
            authUid = "  ",
            deviceLogUid = "log-uid",
            payloadUid = null,
        ) == "log-uid",
    )
    check(
        NudgeDeliveryAckPolicy.resolveRecipientUserId(
            authUid = null,
            deviceLogUid = null,
            payloadUid = null,
        ) == null,
    )

    check(NudgeDeliveryAckPolicy.canAttemptWrite("uid", "uid"))
    check(!NudgeDeliveryAckPolicy.canAttemptWrite(null, "uid"))
    check(!NudgeDeliveryAckPolicy.canAttemptWrite("uid", "other"))
    check(!NudgeDeliveryAckPolicy.canAttemptWrite("", ""))

    val now = 1_000_000L
    check(NudgeDeliveryAckPolicy.isPendingAckFresh(now - 1_000L, now))
    check(!NudgeDeliveryAckPolicy.isPendingAckFresh(now - NudgeDeliveryAckPolicy.maxPendingAgeMs, now))
    check(!NudgeDeliveryAckPolicy.isPendingAckFresh(0L, now))

    check(NudgeDeliveryAckPolicy.shouldOverwrite(null, "played"))
    check(NudgeDeliveryAckPolicy.shouldOverwrite("failed", "played"))
    check(!NudgeDeliveryAckPolicy.shouldOverwrite("played", "failed"))
    check(!NudgeDeliveryAckPolicy.shouldOverwrite("played", "timeout"))
}
