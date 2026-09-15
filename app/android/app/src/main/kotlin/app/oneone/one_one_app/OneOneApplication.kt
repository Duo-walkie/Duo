package app.oneone.one_one_app

import android.app.Application
import android.os.Build
import com.google.firebase.crashlytics.FirebaseCrashlytics

class OneOneApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DeviceLog.init(this)
        DeviceLog.info("LogManager", "Native DeviceLog initialized")
        NudgeDeliveryStatusRtdb.enablePersistence()
        NudgeDeliveryStatusRtdb.warm(this)
        val crashlytics = FirebaseCrashlytics.getInstance()
        crashlytics.setCustomKey("android_version", Build.VERSION.RELEASE ?: "")
        crashlytics.setCustomKey("device_model", Build.MODEL)
        crashlytics.setCustomKey("app_version", DeviceLog.currentAppVersion())
        crashlytics.setCrashlyticsCollectionEnabled(true)
    }
}
