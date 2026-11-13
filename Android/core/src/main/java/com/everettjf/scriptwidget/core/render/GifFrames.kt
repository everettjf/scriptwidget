package com.everettjf.scriptwidget.core.render

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Movie
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Evenly spaced frames of a GIF and the delay between them. */
class GifFrames(val frames: List<Bitmap>, val intervalMilliseconds: Int)

/**
 * Samples a GIF into a bounded set of bitmaps for a widget. A widget cannot
 * run a decoder, so the launcher flips through prepared frames; their total
 * size counts against the widget bitmap budget and is capped here.
 */
object GifSampler {
    const val MAXIMUM_INPUT_BYTES = 8 * 1024 * 1024
    const val MAXIMUM_FRAMES = 24
    private const val MINIMUM_INTERVAL = 80

    /**
     * Returns null when the data is not an animated GIF or cannot be decoded.
     * [width] and [height] are the box in pixels the GIF is fitted into; [maximumBytes] bounds all frames together.
     */
    @Suppress("DEPRECATION")
    fun sample(data: ByteArray, width: Int, height: Int, maximumBytes: Long): GifFrames? {
        if (data.size > MAXIMUM_INPUT_BYTES || width <= 0 || height <= 0) return null
        val movie = runCatching { Movie.decodeByteArray(data, 0, data.size) }.getOrNull() ?: return null
        val duration = movie.duration()
        if (duration <= 0 || movie.width() <= 0 || movie.height() <= 0) return null
        val count = (duration / MINIMUM_INTERVAL).coerceIn(2, MAXIMUM_FRAMES)
        // Fit inside the box, then shrink further until every frame together fits the budget.
        var scale = min(width.toFloat() / movie.width(), height.toFloat() / movie.height())
        val bytes = { s: Float -> (movie.width() * s).toLong() * (movie.height() * s).toLong() * 4L * count }
        if (bytes(scale) > maximumBytes) scale *= sqrt(maximumBytes.toDouble() / bytes(scale)).toFloat()
        val frameWidth = max(1, (movie.width() * scale).toInt())
        val frameHeight = max(1, (movie.height() * scale).toInt())
        val frames = ArrayList<Bitmap>(count)
        for (index in 0 until count) {
            val bitmap = Bitmap.createBitmap(frameWidth, frameHeight, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.scale(frameWidth.toFloat() / movie.width(), frameHeight.toFloat() / movie.height())
            movie.setTime(duration * index / count)
            movie.draw(canvas, 0f, 0f)
            frames += bitmap
        }
        return GifFrames(frames, max(MINIMUM_INTERVAL, duration / count))
    }
}
