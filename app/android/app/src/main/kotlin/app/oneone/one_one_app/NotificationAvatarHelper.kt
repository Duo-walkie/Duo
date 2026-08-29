package app.oneone.one_one_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Builds the large notification icon for nudge notifications, in order:
 * 1. circular Cloudinary profile photo when [photoUrl] is reachable
 * 2. bundled preset avatar when [avatarAsset] is a valid `assets/avatars*` path
 * 3. the app logo (`assets/logo.png` bundled as [new_logo])
 *
 * Network I/O never runs on the caller thread. Use [applyLargeIcon] so the
 * notification can show immediately with the avatar or logo, then refresh
 * when a remote photo arrives.
 */
object NotificationAvatarHelper {
    private val cache = ConcurrentHashMap<String, Bitmap>()
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Cached decode of the app logo for the large-icon fallback. */
    @Volatile
    private var cachedLogoBitmap: Bitmap? = null

    /** Returns the app logo as a square bitmap suitable for a large icon. */
    fun appLogoBitmap(context: Context): Bitmap {
        cachedLogoBitmap?.let { return it }
        val resources = context.applicationContext.resources
        val options = BitmapFactory.Options().apply {
            val densityDpi = resources.displayMetrics.densityDpi
            inDensity = densityDpi
            inTargetDensity = densityDpi
            inScaled = true
        }
        val decoded = BitmapFactory.decodeResource(resources, R.drawable.new_logo, options)
            ?: return Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        val size = (64 * resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val scaled = Bitmap.createScaledBitmap(decoded, size, size, true)
        if (scaled != decoded) decoded.recycle()
        cachedLogoBitmap = scaled
        return scaled
    }

    /** True once [url] has a successfully downloaded photo in the cache. */
    fun hasCachedPhoto(url: String): Boolean {
        val trimmed = url.trim()
        return trimmed.isNotEmpty() && cache.containsKey(trimmed)
    }

    /**
     * Cached photo, bundled avatar, or app logo. Does not hit the network —
     * safe on the main thread.
     */
    fun largeIcon(
        context: Context,
        photoUrl: String?,
        @Suppress("UNUSED_PARAMETER") senderName: String,
        avatarAsset: String? = null,
    ): Bitmap {
        val url = photoUrl?.trim().orEmpty()
        if (url.isNotEmpty()) {
            cache[url]?.let { return it }
        }
        decodeAvatarAsset(context, avatarAsset)?.let { return it }
        return appLogoBitmap(context)
    }

    /**
     * Posts [apply] immediately with a cached photo, bundled avatar, or the
     * app logo, then again on the main thread if a remote photo downloads.
     */
    fun applyLargeIcon(
        context: Context,
        photoUrl: String?,
        senderName: String,
        avatarAsset: String? = null,
        apply: (Bitmap) -> Unit,
    ) {
        val initial = largeIcon(context, photoUrl, senderName, avatarAsset)
        apply(initial)
        val url = photoUrl?.trim().orEmpty()
        if (url.isEmpty() || cache.containsKey(url)) return
        loadAsync(context, photoUrl, senderName, avatarAsset) { bitmap ->
            if (bitmap !== initial) apply(bitmap)
        }
    }

    /**
     * Loads [photoUrl] off the main thread and delivers a circular bitmap
     * on the main thread. Falls back to the bundled avatar, then the app logo.
     */
    fun loadAsync(
        context: Context,
        photoUrl: String?,
        senderName: String,
        avatarAsset: String? = null,
        onReady: (Bitmap) -> Unit,
    ) {
        val appContext = context.applicationContext
        executor.execute {
            val bitmap = downloadOrFallback(appContext, photoUrl, avatarAsset, senderName)
            mainHandler.post { onReady(bitmap) }
        }
    }

    /** Retained for use in non-notification contexts (e.g. inline avatars). */
    fun monogram(context: Context, senderName: String): Bitmap {
        val size = (64 * context.resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val key = "mono:${senderName.trim().lowercase()}:$size"
        cache[key]?.let { return it }
        val letter = senderName.trim()
            .split(Regex("\\s+"))
            .firstOrNull { it.isNotEmpty() }
            ?.removePrefix("@")
            ?.firstOrNull()
            ?.uppercaseChar()
            ?.toString()
            ?: "?"
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(48, 48, 48)
            style = Paint.Style.FILL
        }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.color = Color.WHITE
        paint.textAlign = Paint.Align.CENTER
        paint.textSize = size * 0.42f
        paint.isFakeBoldText = true
        val textY = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(letter, size / 2f, textY, paint)
        cache[key] = bitmap
        return bitmap
    }

    private fun downloadOrFallback(
        context: Context,
        photoUrl: String?,
        avatarAsset: String?,
        senderName: String,
    ): Bitmap {
        val url = photoUrl?.trim().orEmpty()
        if (url.isNotEmpty()) {
            cache[url]?.let { return it }
            val downloaded = downloadCircular(url, context)
            if (downloaded != null) {
                cache[url] = downloaded
                return downloaded
            }
        }
        return largeIcon(context, photoUrl, senderName, avatarAsset)
    }

    private fun decodeAvatarAsset(context: Context, avatarAsset: String?): Bitmap? {
        val path = avatarAsset?.trim().orEmpty()
        if (path.isEmpty()) return null
        if (!path.startsWith("assets/avatars/") && !path.startsWith("assets/avatars2/")) {
            return null
        }
        if (".." in path) return null
        cache["asset:$path"]?.let { return it }
        val candidates = arrayOf("flutter_assets/$path", path)
        for (candidate in candidates) {
            try {
                context.assets.open(candidate).use { stream ->
                    val decoded = BitmapFactory.decodeStream(stream) ?: return@use
                    val circular = toCircular(decoded, context)
                    cache["asset:$path"] = circular
                    return circular
                }
            } catch (_: Exception) {
                // try the next lookup key
            }
        }
        Log.w(VoiceNudgeDiagnostics.tag, "[AVATAR] asset miss $path")
        return null
    }

    private fun downloadCircular(url: String, context: Context): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            val fetchUrl = thumbnailUrl(url)
            connection = (URL(fetchUrl).openConnection() as HttpURLConnection).apply {
                connectTimeout = 8_000
                readTimeout = 8_000
                instanceFollowRedirects = true
                doInput = true
                setRequestProperty("Accept", "image/*")
                setRequestProperty("User-Agent", "OneOne-Android")
            }
            val code = connection.responseCode
            if (code !in 200..299) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[AVATAR] HTTP $code host=${URL(fetchUrl).host}",
                )
                return null
            }
            val bytes = connection.inputStream.use { it.readBytes() }
            if (bytes.isEmpty() || bytes.size > 8_000_000) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[AVATAR] rejected size=${bytes.size}",
                )
                return null
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val target = 128
            val longest = maxOf(bounds.outWidth, bounds.outHeight).coerceAtLeast(1)
            val sample = Integer.highestOneBit((longest / target).coerceAtLeast(1))
            val decode = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decode)
                ?: return null
            toCircular(decoded, context)
        } catch (error: Exception) {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[AVATAR] download failed ${error.javaClass.simpleName}: ${error.message}",
            )
            null
        } finally {
            connection?.disconnect()
        }
    }

    /** Ask Cloudinary for a 128px crop so camera uploads don't blow the timeout. */
    private fun thumbnailUrl(url: String): String {
        val marker = "/image/upload/"
        val index = url.indexOf(marker)
        if (index < 0) return url
        val insertAt = index + marker.length
        val after = url.substring(insertAt)
        if (
            after.startsWith("w_") ||
            after.startsWith("c_") ||
            after.startsWith("h_") ||
            after.startsWith("f_") ||
            after.startsWith("q_")
        ) {
            return url
        }
        return url.substring(0, insertAt) + "w_128,h_128,c_fill,f_auto,q_auto/" + after
    }

    private fun toCircular(source: Bitmap, context: Context): Bitmap {
        val size = (64 * context.resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val scaled = Bitmap.createScaledBitmap(source, size, size, true)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val rect = Rect(0, 0, size, size)
        canvas.drawARGB(0, 0, 0, 0)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(scaled, rect, RectF(rect), paint)
        if (scaled != source) scaled.recycle()
        return output
    }
}
