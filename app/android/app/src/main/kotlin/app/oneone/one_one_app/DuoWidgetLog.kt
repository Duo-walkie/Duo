package app.oneone.one_one_app

import android.util.Log

/**
 * Structured diagnostics for the home-screen widget. Filter logcat with:
 *   adb logcat -s DuoWidget:D OneOneFCM:I
 *
 * Checkpoint codes make it obvious which stage failed when the launcher
 * shows "Can't load widget" (that message itself is host-side and often
 * has no stack in our process — these breadcrumbs still tell us what we
 * last successfully pushed).
 */
object DuoWidgetLog {
    const val tag = "DuoWidget"

    fun d(checkpoint: String, message: String) {
        Log.d(tag, "[$checkpoint] $message")
        DeviceLog.info(tag, "[$checkpoint] $message")
    }

    fun i(checkpoint: String, message: String) {
        Log.i(tag, "[$checkpoint] $message")
        DeviceLog.info(tag, "[$checkpoint] $message")
    }

    fun w(checkpoint: String, message: String, error: Throwable? = null) {
        if (error != null) {
            Log.w(tag, "[$checkpoint] $message", error)
            DeviceLog.warn(tag, "[$checkpoint] $message: ${error.message}")
        } else {
            Log.w(tag, "[$checkpoint] $message")
            DeviceLog.warn(tag, "[$checkpoint] $message")
        }
    }

    fun e(checkpoint: String, message: String, error: Throwable? = null) {
        if (error != null) {
            Log.e(tag, "[$checkpoint] $message", error)
            DeviceLog.error(tag, "[$checkpoint] $message: ${error.javaClass.simpleName}: ${error.message}")
        } else {
            Log.e(tag, "[$checkpoint] $message")
            DeviceLog.error(tag, "[$checkpoint] $message")
        }
    }

    fun layoutName(layoutId: Int): String = when (layoutId) {
        R.layout.duo_widget_small -> "small"
        R.layout.duo_widget_medium -> "medium"
        R.layout.duo_widget_large -> "large"
        R.layout.duo_widget_fallback -> "fallback"
        else -> "unknown(0x${Integer.toHexString(layoutId)})"
    }
}
