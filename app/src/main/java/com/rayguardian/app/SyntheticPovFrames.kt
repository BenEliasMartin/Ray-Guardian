package com.rayguardian.app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.util.Base64
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.sin

/**
 * Generates ordered first-person smart-glasses JPEG frames for reproducible testing on
 * Android emulators and Meta MockDeviceKit when physical glasses camera optics are not attached.
 */
object SyntheticPovFrames {
    enum class Scene(val title: String, val description: String) {
        ELDERLY_FALL(
            "Elderly Person Falling",
            "First-person Meta smart-glasses POV frames (t = 1.0s, 3.0s, 4.8s) indoors.",
        ),
        OPEN_FIRE(
            "Large Open Fire",
            "First-person Meta smart-glasses POV frames (t = 1.0s, 3.0s, 4.8s) indoors.",
        ),
    }

    fun generateOrderedFrames(scene: Scene): List<String> =
        listOf(1.0f, 3.0f, 4.8f).map { seconds -> renderJpegDataUrl(scene, seconds) }

    private fun renderJpegDataUrl(scene: Scene, sec: Float): String {
        val width = 512
        val height = 288
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            when (scene) {
                Scene.ELDERLY_FALL -> drawElderlyFall(canvas, width.toFloat(), height.toFloat(), sec)
                Scene.OPEN_FIRE -> drawOpenFire(canvas, width.toFloat(), height.toFloat(), sec)
            }
            val bytes = ByteArrayOutputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 78, out)
                out.toByteArray()
            }
            return "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } finally {
            bitmap.recycle()
        }
    }

    private fun drawRoom(canvas: Canvas, w: Float, h: Float, warmFactor: Float) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val topWall = if (warmFactor > 0f) {
            Color.rgb((55 + 60 * warmFactor).toInt(), (42 + 15 * warmFactor).toInt(), 38)
        } else {
            Color.parseColor("#D8DDD8")
        }
        val bottomWall = if (warmFactor > 0f) {
            Color.rgb((85 + 90 * warmFactor).toInt(), (52 + 20 * warmFactor).toInt(), 40)
        } else {
            Color.parseColor("#BFC7C0")
        }
        paint.shader = LinearGradient(0f, 0f, 0f, h * 0.62f, topWall, bottomWall, Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, w, h * 0.62f, paint)

        paint.shader = LinearGradient(
            0f,
            h * 0.62f,
            0f,
            h,
            Color.parseColor("#8C6D4F"),
            Color.parseColor("#5E452E"),
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, h * 0.62f, w, h, paint)
        paint.shader = null

        paint.color = Color.parseColor("#E8ECE8")
        canvas.drawRect(0f, h * 0.60f, w, 6f, paint)
        paint.color = Color.parseColor("#6F7972")
        canvas.drawRect(w * 0.13f, h * 0.14f, w * 0.23f, h * 0.60f, paint)
    }

    private fun drawElderlyFall(canvas: Canvas, w: Float, h: Float, sec: Float) {
        drawRoom(canvas, w, h, 0f)
        val progress = ((sec - 1.6f) / 1.9f).coerceIn(0f, 1f)
        val cx = w * 0.52f
        val floorY = h * 0.82f
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)

        // Silver walking frame tipping over
        canvas.save()
        canvas.translate(cx + 42f + progress * 30f, floorY - 4f)
        canvas.rotate(progress * 66f)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 4f
        paint.color = Color.parseColor("#D9E2EC")
        canvas.drawRect(-20f, -64f, 20f, 0f, paint)
        canvas.drawLine(-20f, -34f, 20f, -34f, paint)
        canvas.restore()

        // Elderly person falling onto floor
        canvas.save()
        canvas.translate(cx - progress * 22f, floorY - 6f + progress * 10f)
        canvas.rotate(-progress * 84f)

        paint.style = Paint.Style.STROKE
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeWidth = 13f
        paint.color = Color.parseColor("#2F3E4E")
        canvas.drawLine(-7f, -48f, -11f, 0f, paint)
        canvas.drawLine(9f, -48f, 13f + progress * 9f, -2f, paint)

        paint.style = Paint.Style.FILL
        paint.color = Color.parseColor("#4A6FA5")
        canvas.drawRoundRect(RectF(-18f, -104f, 18f, -44f), 10f, 10f, paint)

        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 10f
        canvas.drawLine(-15f, -94f, -34f, -62f - progress * 16f, paint)
        canvas.drawLine(15f, -94f, 34f, -66f, paint)

        paint.style = Paint.Style.FILL
        paint.color = Color.parseColor("#F0C8A8")
        canvas.drawCircle(0f, -120f, 15f, paint)
        paint.color = Color.parseColor("#DCDFE3")
        canvas.drawArc(RectF(-15.5f, -138f, 15.5f, -108f), 180f, 180f, true, paint)
        canvas.restore()
    }

    private fun drawOpenFire(canvas: Canvas, w: Float, h: Float, sec: Float) {
        val intensity = (0.22f + (sec / 4.2f) * 0.85f).coerceIn(0.2f, 1.0f)
        drawRoom(canvas, w, h, intensity * 0.75f)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val baseX = w * 0.52f
        val baseY = h * 0.86f
        val spread = 50f + intensity * 140f
        val maxFlameH = 44f + intensity * 155f

        // Heavy dark smoke plume
        paint.style = Paint.Style.FILL
        for (i in 0 until 14) {
            val drift = sin(sec * 2.2f + i) * 18f
            val sx = baseX + ((i % 5) - 2) * (spread * 0.40f) + drift
            val sy = baseY - maxFlameH * 0.65f - i * 12f * intensity
            val radius = 24f + i * 4.5f * intensity
            paint.color = Color.argb(((0.25f + intensity * 0.34f) * 255).toInt(), 28, 28, 30)
            canvas.drawCircle(sx, sy, radius, paint)
        }

        // Layered roaring flames
        data class FlameLayer(val color: Int, val scaleW: Float, val scaleH: Float, val tongues: Int)
        val layers = listOf(
            FlameLayer(Color.parseColor("#D92B04"), 1.0f, 1.0f, 11),
            FlameLayer(Color.parseColor("#FF6A00"), 0.82f, 0.82f, 9),
            FlameLayer(Color.parseColor("#FFC400"), 0.58f, 0.62f, 7),
            FlameLayer(Color.parseColor("#FFF6CC"), 0.34f, 0.38f, 5),
        )
        for (layer in layers) {
            paint.color = layer.color
            for (i in 0 until layer.tongues) {
                val frac = if (layer.tongues == 1) 0f else (i.toFloat() / (layer.tongues - 1)) - 0.5f
                val flicker = sin(sec * 9f + i * 1.7f) * 11f * intensity
                val fx = baseX + frac * spread * 1.45f * layer.scaleW
                val fw = (25f + intensity * 30f) * layer.scaleW
                val fh = (maxFlameH * (1f - abs(frac) * 0.55f) + flicker) * layer.scaleH
                val path = Path().apply {
                    moveTo(fx - fw, baseY)
                    quadTo(fx - fw * 0.4f, baseY - fh * 0.65f, fx + flicker * 0.4f, baseY - fh)
                    quadTo(fx + fw * 0.4f, baseY - fh * 0.65f, fx + fw, baseY)
                    close()
                }
                canvas.drawPath(path, paint)
            }
        }
    }
}
