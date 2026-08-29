package app.oneone.one_one_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * Home-screen widget provider. All rendering lives in [DuoWidgetRenderer];
 * this class only wires the AppWidgetProvider lifecycle callbacks to it and
 * cleans up per-widget group-selection overrides when an instance is removed.
 */
class DuoHomeWidgetProvider : AppWidgetProvider() {
    override fun onEnabled(context: Context) {
        DuoWidgetLog.i("P-01", "onEnabled — first widget instance placed")
    }

    override fun onDisabled(context: Context) {
        DuoWidgetLog.i("P-02", "onDisabled — last widget instance removed")
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        DuoWidgetLog.i(
            "P-03",
            "onUpdate ids=${appWidgetIds.toList()} " +
                "groupsCached=${DuoWidgetSnapshotStore.readGroups(context).size} " +
                "lastActive=${DuoWidgetSnapshotStore.lastActiveGroupId(context) ?: "none"} " +
                "userId=${DuoWidgetSnapshotStore.userId(context)?.takeLast(6) ?: "none"}",
        )
        for (appWidgetId in appWidgetIds) {
            try {
                logOptions("P-03a", appWidgetManager, appWidgetId)
                DuoWidgetRenderer.updateWidget(context, appWidgetManager, appWidgetId)
            } catch (error: Exception) {
                DuoWidgetLog.e("P-03e", "onUpdate crashed id=$appWidgetId", error)
            }
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        DuoWidgetLog.i(
            "P-04",
            "onAppWidgetOptionsChanged id=$appWidgetId " +
                "minW=${newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)} " +
                "minH=${newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)} " +
                "maxW=${newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)} " +
                "maxH=${newOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)}",
        )
        try {
            DuoWidgetRenderer.updateWidget(context, appWidgetManager, appWidgetId)
        } catch (error: Exception) {
            DuoWidgetLog.e("P-04e", "onAppWidgetOptionsChanged crashed id=$appWidgetId", error)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        DuoWidgetLog.i("P-05", "onDeleted ids=${appWidgetIds.toList()}")
        for (appWidgetId in appWidgetIds) {
            DuoWidgetSnapshotStore.clearWidget(context, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        DuoWidgetLog.d(
            "P-06",
            "onReceive action=${intent.action} " +
                "extras=${intent.extras?.keySet()?.joinToString() ?: "none"}",
        )
        super.onReceive(context, intent)
    }

    private fun logOptions(checkpoint: String, manager: AppWidgetManager, appWidgetId: Int) {
        val options = manager.getAppWidgetOptions(appWidgetId)
        DuoWidgetLog.d(
            checkpoint,
            "id=$appWidgetId " +
                "minW=${options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)} " +
                "minH=${options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)}",
        )
    }
}
