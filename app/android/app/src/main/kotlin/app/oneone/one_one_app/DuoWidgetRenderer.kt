package app.oneone.one_one_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Rendering-time state a single widget instance is currently showing. */
private enum class DuoWidgetState { IDLE, PENDING, ONLINE }

/**
 * Builds and pushes [RemoteViews] for every Duo home-screen widget instance.
 *
 * Avatar photos are bound as tiny copied bitmaps (never the notification
 * cache object). Missing photos prefetch once, then a single debounced
 * [updateAll] refreshes every instance.
 */
object DuoWidgetRenderer {
    private const val avatarPx = 36
    private const val prefetchDebounceMs = 500L

    private val avatarIds = intArrayOf(
        R.id.avatar_1,
        R.id.avatar_2,
        R.id.avatar_3,
        R.id.avatar_4,
        R.id.avatar_5,
    )

    private val avatarMonoIds = intArrayOf(
        R.id.avatar_1_mono,
        R.id.avatar_2_mono,
        R.id.avatar_3_mono,
        R.id.avatar_4_mono,
        R.id.avatar_5_mono,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val attemptedPhotoUrls = ConcurrentHashMap.newKeySet<String>()
    private val prefetchLock = Any()
    private val inFlightPhotos = AtomicInteger(0)
    private var prefetchRefreshConsumed = false
    private var prefetchDebouncePosted = false
    private var prefetchContext: Context? = null

    private val prefetchDebounceRunnable = Runnable {
        flushPhotoRefresh("debounce")
    }

    fun updateAll(context: Context) {
        val appContext = context.applicationContext
        val manager = AppWidgetManager.getInstance(appContext)
        val ids = manager.getAppWidgetIds(
            ComponentName(appContext, DuoHomeWidgetProvider::class.java),
        )
        DuoWidgetLog.i("R-00", "updateAll count=${ids.size} ids=${ids.toList()}")
        for (appWidgetId in ids) {
            updateWidget(appContext, manager, appWidgetId)
        }
    }

    fun updateWidget(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
        val appContext = context.applicationContext
        var stage = "start"
        try {
            stage = "pickLayout"
            val layoutId = pickLayout(manager, appWidgetId)
            DuoWidgetLog.i(
                "R-01",
                "id=$appWidgetId layout=${DuoWidgetLog.layoutName(layoutId)} " +
                    "mode=tiny-bitmap pkg=${appContext.packageName}",
            )

            stage = "newRemoteViews"
            val views = RemoteViews(appContext.packageName, layoutId)

            stage = "bindWidget"
            bindWidget(appContext, views, appWidgetId, layoutId)

            stage = "updateAppWidget"
            manager.updateAppWidget(appWidgetId, views)
            DuoWidgetLog.i(
                "R-02",
                "pushed id=$appWidgetId layout=${DuoWidgetLog.layoutName(layoutId)} OK",
            )
        } catch (error: Exception) {
            DuoWidgetLog.e(
                "R-99",
                "updateWidget FAILED id=$appWidgetId stage=$stage " +
                    "type=${error.javaClass.name}",
                error,
            )
            pushFallback(appContext, manager, appWidgetId)
        }
    }

    private fun pickLayout(manager: AppWidgetManager, appWidgetId: Int): Int {
        val options = manager.getAppWidgetOptions(appWidgetId)
        val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        val minHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        val layoutId = when {
            minWidth <= 0 || minHeight <= 0 -> R.layout.duo_widget_medium
            minWidth <= 150 && minHeight <= 150 -> R.layout.duo_widget_small
            minHeight >= 220 -> R.layout.duo_widget_large
            else -> R.layout.duo_widget_medium
        }
        DuoWidgetLog.d(
            "R-01a",
            "id=$appWidgetId size=${minWidth}x${minHeight} -> ${DuoWidgetLog.layoutName(layoutId)}",
        )
        return layoutId
    }

    private fun bindWidget(
        context: Context,
        views: RemoteViews,
        appWidgetId: Int,
        layoutId: Int,
    ) {
        val group = DuoWidgetSnapshotStore.groupForWidget(context, appWidgetId)
        if (group == null) {
            DuoWidgetLog.w(
                "R-10",
                "id=$appWidgetId no group snapshot — signed-out chrome " +
                    "(groups=${DuoWidgetSnapshotStore.readGroups(context).size})",
            )
            renderSignedOut(context, views)
            return
        }

        DuoWidgetLog.i(
            "R-11",
            "id=$appWidgetId group=${group.name} " +
                "groupIdSuffix=${group.groupId.takeLast(6)} members=${group.members.size}",
        )
        trySetText(views, R.id.group_name, group.name)

        if (layoutId == R.layout.duo_widget_small) {
            hideAvatars(views)
            prefetchPhotos(context, pendingPhotoUrls(context, group.members))
        } else {
            bindAvatars(context, views, group.members)
        }

        val pending = IncomingNudgeStore.pendingForGroup(context, group.groupId)
        val liveGroupId = ActiveVoiceSessionStore.readGroupId(context)
        val isOnline = liveGroupId != null && liveGroupId == group.groupId
        val state = when {
            isOnline -> DuoWidgetState.ONLINE
            pending != null -> DuoWidgetState.PENDING
            else -> DuoWidgetState.IDLE
        }
        DuoWidgetLog.i(
            "R-12",
            "id=$appWidgetId state=$state " +
                "pendingEvent=${pending?.get("eventId")?.takeLast(6) ?: "none"} " +
                "liveGroup=${liveGroupId?.takeLast(6) ?: "none"}",
        )
        renderState(views, state, pending)
        setActionIntents(context, views, appWidgetId, group.groupId, pending?.get("responseUrl"))
    }

    /**
     * Bind up to 5 member avatars. Photos use a 36px copied bitmap; any
     * failure falls back to a locally drawn monogram bitmap, then a
     * TextView sibling.
     */
    private fun bindAvatars(
        context: Context,
        views: RemoteViews,
        members: List<DuoWidgetMember>,
    ) {
        val logo = NotificationAvatarHelper.appLogoBitmap(context)
        val pendingUrls = ArrayList<String>()
        var shown = 0

        for ((slot, viewId) in avatarIds.withIndex()) {
            val monoId = avatarMonoIds.getOrNull(slot) ?: 0
            if (slot >= members.size) {
                trySetVisibility(views, viewId, View.GONE)
                if (monoId != 0) trySetVisibility(views, monoId, View.GONE)
                continue
            }
            val member = members[slot]
            val url = member.photoUrl?.trim().orEmpty()
            var source: Bitmap? = null
            if (url.isNotEmpty()) {
                val cached = NotificationAvatarHelper.largeIcon(
                    context,
                    url,
                    member.displayName,
                    null,
                )
                if (cached !== logo) {
                    source = cached
                } else {
                    pendingUrls.add(url)
                }
            }
            if (source == null) {
                source = monogramBitmap(member.displayName)
            }
            val bound = bindAvatarSlot(views, viewId, monoId, source, member.displayName)
            if (bound) shown++
        }

        val overflow = members.size - avatarIds.size
        if (overflow > 0) {
            trySetVisibility(views, R.id.avatar_overflow, View.VISIBLE)
            trySetText(views, R.id.avatar_overflow, "+$overflow")
        } else {
            trySetVisibility(views, R.id.avatar_overflow, View.GONE)
        }
        DuoWidgetLog.i(
            "R-21",
            "avatars bound shown=$shown " +
                "overflow=${overflow.coerceAtLeast(0)} pendingPhotos=${pendingUrls.size}",
        )
        prefetchPhotos(context, pendingUrls)
    }

    private fun bindAvatarSlot(
        views: RemoteViews,
        imageId: Int,
        monoId: Int,
        source: Bitmap,
        displayName: String,
    ): Boolean {
        val copy = copyWidgetBitmap(source)
        if (copy != null) {
            try {
                views.setImageViewBitmap(imageId, copy)
                trySetVisibility(views, imageId, View.VISIBLE)
                if (monoId != 0) trySetVisibility(views, monoId, View.GONE)
                return true
            } catch (error: Exception) {
                DuoWidgetLog.w(
                    "R-20",
                    "setImageViewBitmap failed id=0x${Integer.toHexString(imageId)}",
                    error,
                )
            }
        }
        try {
            views.setImageViewResource(imageId, R.drawable.bg_widget_btn_oval)
            trySetVisibility(views, imageId, View.VISIBLE)
        } catch (_: Exception) {
            trySetVisibility(views, imageId, View.GONE)
        }
        if (monoId != 0) {
            trySetVisibility(views, monoId, View.VISIBLE)
            trySetText(views, monoId, monogram(displayName))
            return true
        }
        return false
    }

    /**
     * Scale to a binder-safe size and copy so the launcher recycling the
     * parcelled bitmap cannot poison [NotificationAvatarHelper]'s cache.
     */
    private fun copyWidgetBitmap(source: Bitmap): Bitmap? {
        return try {
            if (source.isRecycled) return null
            val scaled = if (source.width == avatarPx && source.height == avatarPx) {
                source
            } else {
                Bitmap.createScaledBitmap(source, avatarPx, avatarPx, true)
            }
            val copy = scaled.copy(Bitmap.Config.ARGB_8888, false)
            if (scaled !== source && scaled !== copy) {
                scaled.recycle()
            }
            copy
        } catch (error: Exception) {
            DuoWidgetLog.w("R-20", "copyWidgetBitmap failed", error)
            null
        }
    }

    private fun monogramBitmap(displayName: String): Bitmap {
        val size = avatarPx
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#222222")
            style = Paint.Style.FILL
        }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.color = Color.parseColor("#F0EDE8")
        paint.textAlign = Paint.Align.CENTER
        paint.textSize = size * 0.42f
        paint.isFakeBoldText = true
        val letter = monogram(displayName)
        val textY = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(letter, size / 2f, textY, paint)
        return bitmap
    }

    private fun pendingPhotoUrls(context: Context, members: List<DuoWidgetMember>): List<String> {
        val logo = NotificationAvatarHelper.appLogoBitmap(context)
        val urls = ArrayList<String>()
        for (member in members.take(avatarIds.size)) {
            val url = member.photoUrl?.trim().orEmpty()
            if (url.isEmpty()) continue
            val cached = NotificationAvatarHelper.largeIcon(
                context,
                url,
                member.displayName,
                null,
            )
            if (cached === logo) urls.add(url)
        }
        return urls
    }

    private fun prefetchPhotos(context: Context, urls: List<String>) {
        val unique = urls.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
            .filter { attemptedPhotoUrls.add(it) }
        if (unique.isEmpty()) return
        val appContext = context.applicationContext
        synchronized(prefetchLock) {
            prefetchContext = appContext
            prefetchRefreshConsumed = false
            inFlightPhotos.addAndGet(unique.size)
            if (!prefetchDebouncePosted) {
                prefetchDebouncePosted = true
                mainHandler.postDelayed(prefetchDebounceRunnable, prefetchDebounceMs)
            }
        }
        DuoWidgetLog.d("R-22", "prefetch start count=${unique.size}")
        for (url in unique) {
            NotificationAvatarHelper.loadAsync(appContext, url, "", null) {
                onPhotoReady()
            }
        }
    }

    private fun onPhotoReady() {
        val remaining = inFlightPhotos.updateAndGet { (it - 1).coerceAtLeast(0) }
        if (remaining == 0) {
            flushPhotoRefresh("all-ready")
        }
    }

    private fun flushPhotoRefresh(reason: String) {
        val ctx: Context
        synchronized(prefetchLock) {
            if (prefetchRefreshConsumed) return
            prefetchRefreshConsumed = true
            prefetchDebouncePosted = false
            mainHandler.removeCallbacks(prefetchDebounceRunnable)
            ctx = prefetchContext ?: return
        }
        DuoWidgetLog.i("R-22", "photo refresh reason=$reason")
        mainHandler.post { updateAll(ctx) }
    }

    private fun monogram(displayName: String): String {
        val trimmed = displayName.trim()
        if (trimmed.isEmpty()) return "?"
        val parts = trimmed.split(Regex("\\s+"))
        return if (parts.size >= 2) {
            "${parts[0].first().uppercaseChar()}${parts[1].first().uppercaseChar()}"
        } else {
            trimmed.first().uppercaseChar().toString()
        }
    }

    private fun renderSignedOut(context: Context, views: RemoteViews) {
        trySetText(views, R.id.group_name, "Open Duo")
        trySetText(views, R.id.status_pill, "Sign in to set up your widget")
        hideAvatars(views)
        trySetVisibility(views, R.id.btn_decline, View.GONE)
        trySetVisibility(views, R.id.btn_accept, View.GONE)
        trySetVisibility(views, R.id.btn_ring, View.GONE)
        trySetVisibility(views, R.id.btn_notify, View.GONE)
        trySetVisibility(views, R.id.btn_mic, View.GONE)
        trySetVisibility(views, R.id.btn_next, View.GONE)
        trySetVisibility(views, R.id.live_label, View.GONE)
        trySetClick(views, R.id.widget_root, openAppIntent(context))
    }

    private fun hideAvatars(views: RemoteViews) {
        for (viewId in avatarIds) {
            trySetVisibility(views, viewId, View.GONE)
        }
        for (viewId in avatarMonoIds) {
            trySetVisibility(views, viewId, View.GONE)
        }
        trySetVisibility(views, R.id.avatar_overflow, View.GONE)
    }

    private fun renderState(
        views: RemoteViews,
        state: DuoWidgetState,
        pending: Map<String, String>?,
    ) {
        when (state) {
            DuoWidgetState.ONLINE -> {
                trySetText(views, R.id.status_pill, "Live now")
                trySetVisibility(views, R.id.live_label, View.VISIBLE)
                trySetVisibility(views, R.id.btn_decline, View.GONE)
                trySetVisibility(views, R.id.btn_accept, View.GONE)
                trySetVisibility(views, R.id.btn_ring, View.GONE)
                trySetVisibility(views, R.id.btn_notify, View.GONE)
                trySetVisibility(views, R.id.btn_mic, View.VISIBLE)
            }
            DuoWidgetState.PENDING -> {
                val senderName = pending?.get("senderName") ?: "A friend"
                trySetText(views, R.id.status_pill, "$senderName nudged you")
                trySetVisibility(views, R.id.live_label, View.GONE)
                trySetVisibility(views, R.id.btn_decline, View.VISIBLE)
                trySetVisibility(views, R.id.btn_accept, View.VISIBLE)
                trySetVisibility(views, R.id.btn_ring, View.GONE)
                trySetVisibility(views, R.id.btn_notify, View.GONE)
                trySetVisibility(views, R.id.btn_mic, View.VISIBLE)
            }
            DuoWidgetState.IDLE -> {
                trySetText(views, R.id.status_pill, "Tap mic to nudge")
                trySetVisibility(views, R.id.live_label, View.GONE)
                trySetVisibility(views, R.id.btn_decline, View.GONE)
                trySetVisibility(views, R.id.btn_accept, View.GONE)
                trySetVisibility(views, R.id.btn_ring, View.VISIBLE)
                trySetVisibility(views, R.id.btn_notify, View.VISIBLE)
                trySetVisibility(views, R.id.btn_mic, View.VISIBLE)
            }
        }
    }

    private fun setActionIntents(
        context: Context,
        views: RemoteViews,
        appWidgetId: Int,
        groupId: String,
        responseUrl: String?,
    ) {
        trySetClick(
            views,
            R.id.btn_next,
            broadcastIntent(context, appWidgetId, 1, DuoWidgetActionReceiver.actionNextGroup, groupId, null),
        )
        trySetClick(
            views,
            R.id.btn_ring,
            broadcastIntent(context, appWidgetId, 2, DuoWidgetActionReceiver.actionRing, groupId, null),
        )
        trySetClick(
            views,
            R.id.btn_notify,
            broadcastIntent(context, appWidgetId, 3, DuoWidgetActionReceiver.actionNotify, groupId, null),
        )
        trySetClick(
            views,
            R.id.btn_decline,
            broadcastIntent(context, appWidgetId, 4, DuoWidgetActionReceiver.actionDecline, groupId, responseUrl),
        )
        trySetClick(
            views,
            R.id.btn_accept,
            broadcastIntent(context, appWidgetId, 5, DuoWidgetActionReceiver.actionAccept, groupId, responseUrl),
        )
        val micIntent = Intent(context, QuickRecordActivity::class.java).apply {
            putExtra(QuickRecordActivity.extraGroupId, groupId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val micPendingIntent = PendingIntent.getActivity(
            context,
            appWidgetId * 10 + 6,
            micIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        trySetClick(views, R.id.btn_mic, micPendingIntent)
        // Do NOT also click-bind widget_root when children have actions —
        // some OEM hosts mishandle nested PendingIntents.
    }

    private fun broadcastIntent(
        context: Context,
        appWidgetId: Int,
        actionSlot: Int,
        action: String,
        groupId: String,
        responseUrl: String?,
    ): PendingIntent {
        val intent = Intent(context, DuoWidgetActionReceiver::class.java).apply {
            this.action = action
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            putExtra(DuoWidgetActionReceiver.extraGroupId, groupId)
            if (!responseUrl.isNullOrBlank()) {
                putExtra(DuoWidgetActionReceiver.extraResponseUrl, responseUrl)
            }
        }
        return PendingIntent.getBroadcast(
            context,
            appWidgetId * 10 + actionSlot,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun pushFallback(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
    ) {
        DuoWidgetLog.w("R-90", "pushing fallback layout for id=$appWidgetId")
        try {
            val views = RemoteViews(context.packageName, R.layout.duo_widget_fallback)
            views.setTextViewText(R.id.group_name, "Duo")
            views.setTextViewText(R.id.status_pill, "Open the app")
            views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))
            manager.updateAppWidget(appWidgetId, views)
            DuoWidgetLog.i("R-91", "fallback pushed OK id=$appWidgetId")
        } catch (error: Exception) {
            DuoWidgetLog.e("R-92", "fallback bind failed id=$appWidgetId", error)
            try {
                manager.updateAppWidget(
                    appWidgetId,
                    RemoteViews(context.packageName, R.layout.duo_widget_fallback),
                )
                DuoWidgetLog.i("R-93", "bare fallback pushed id=$appWidgetId")
            } catch (ignored: Exception) {
                DuoWidgetLog.e("R-94", "bare fallback FAILED id=$appWidgetId", ignored)
            }
        }
    }

    private fun trySetText(views: RemoteViews, id: Int, text: CharSequence) {
        try {
            views.setTextViewText(id, text)
        } catch (error: Exception) {
            DuoWidgetLog.w("R-30", "setTextViewText 0x${Integer.toHexString(id)}", error)
        }
    }

    private fun trySetVisibility(views: RemoteViews, id: Int, visibility: Int) {
        try {
            views.setViewVisibility(id, visibility)
        } catch (error: Exception) {
            DuoWidgetLog.w("R-31", "setViewVisibility 0x${Integer.toHexString(id)}", error)
        }
    }

    private fun trySetClick(views: RemoteViews, id: Int, intent: PendingIntent) {
        try {
            views.setOnClickPendingIntent(id, intent)
        } catch (error: Exception) {
            DuoWidgetLog.w("R-32", "setOnClickPendingIntent 0x${Integer.toHexString(id)}", error)
        }
    }
}
