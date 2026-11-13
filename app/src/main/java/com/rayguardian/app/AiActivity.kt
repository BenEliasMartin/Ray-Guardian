package com.rayguardian.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Base64
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class AiActivity : ComponentActivity() {
    private val client = AiClient()
    private var inference: Job? = null
    private var imageDataUrl: String? = null
    private var busy = false
    private var requestGeneration = 0
    private lateinit var description: EditText
    private lateinit var consent: CheckBox
    private lateinit var analyzeButton: Button
    private lateinit var imageButton: Button
    private lateinit var removeButton: Button
    private lateinit var result: TextView
    private lateinit var imageStatus: TextView
    private lateinit var preview: ImageView

    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult
        lifecycleScope.launch {
            imageButton.isEnabled = false
            analyzeButton.isEnabled = false
            imageStatus.text = "Preparing image…"
            try {
                val bytes = withContext(Dispatchers.IO) {
                    val source = ImageDecoder.createSource(contentResolver, uri)
                    val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                        check(info.size.width.toLong() * info.size.height <= 50_000_000) { "Choose a smaller image." }
                        val scale = minOf(1.0, 768.0 / maxOf(info.size.width, info.size.height))
                        decoder.setTargetSize(maxOf(1, (info.size.width * scale).toInt()), maxOf(1, (info.size.height * scale).toInt()))
                        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    }
                    try {
                        ByteArrayOutputStream().use { output ->
                            check(bitmap.compress(Bitmap.CompressFormat.JPEG, 78, output))
                            output.toByteArray().also { check(it.size <= 768 * 1024) { "Choose a smaller image." } }
                        }
                    } finally { bitmap.recycle() }
                }
                imageDataUrl = "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
                preview.setImageBitmap(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
                preview.visibility = View.VISIBLE
                removeButton.visibility = View.VISIBLE
                imageStatus.text = "Image selected. A resized copy will be sent only when you choose Analyze."
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                imageDataUrl = null
                preview.setImageDrawable(null)
                preview.visibility = View.GONE
                removeButton.visibility = View.GONE
                imageStatus.text = "This image could not be prepared. Choose another JPEG or PNG."
            } finally {
                imageButton.isEnabled = true
                analyzeButton.isEnabled = true
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.parseColor("#F6F7F4")) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(28), dp(22), dp(32))
        }
        scroll.addView(layout)
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            layout.setPadding(dp(22), dp(28) + bars.top, dp(22), dp(32) + bars.bottom)
            insets
        }
        setContentView(scroll)
        layout.addView(text("NEMOTRON  /  AI CONTEXT", 12, true))
        layout.addView(text("Make sense of\nthe context.", 32, true))
        layout.addView(text("Submit a description and an optional image for an AI-generated summary. This does not detect an emergency, diagnose a condition, or contact anyone.", 15))
        layout.addView(text("Description", 16, true))
        description = EditText(this).apply {
            hint = "Describe what happened"
            minLines = 3
            maxLines = 8
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            filters = arrayOf(android.text.InputFilter.LengthFilter(4000))
            contentDescription = "Context description"
            setText(intent.getStringExtra("context_description")?.take(4000)
                ?: "Demo scenario: A person stumbles while jogging, then stands up and says they are okay.")
        }
        layout.addView(description)
        imageStatus = text("No image selected. Your camera and glasses feed are not accessed.", 13)
        layout.addView(imageStatus)
        preview = ImageView(this).apply {
            visibility = View.GONE
            contentDescription = "Selected image preview"
            adjustViewBounds = true
            maxHeight = dp(180)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        layout.addView(preview)
        imageButton = button("Choose an image", false) { picker.launch(arrayOf("image/jpeg", "image/png")) }
        layout.addView(imageButton)
        removeButton = button("Remove image", false) {
            imageDataUrl = null
            preview.setImageDrawable(null)
            preview.visibility = View.GONE
            removeButton.visibility = View.GONE
            imageStatus.text = "No image selected."
        }.apply { visibility = View.GONE }
        layout.addView(removeButton)
        consent = CheckBox(this).apply {
            text = "I agree to send this description and selected image to Verda / Nemotron for analysis."
            textSize = 14f
            setPadding(0, dp(14), 0, dp(14))
        }
        layout.addView(consent)
        analyzeButton = button("Analyze with Nemotron", true) { submit() }
        layout.addView(analyzeButton)
        layout.addView(button("Back to Ray Guardian", false) { finish() })
        result = text("AI summaries may be wrong or incomplete. They do not change any alert or rehearsal state.", 15).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        layout.addView(result)
    }

    private fun submit() {
        if (busy) return
        if (!consent.isChecked) {
            result.text = "Confirm consent before sending context to Nemotron."
            return
        }
        val submittedDescription = description.text.toString().trim()
        if (submittedDescription.isEmpty()) {
            description.error = "Add a description."
            return
        }
        if (BuildConfig.AI_CLIENT_TOKEN.isBlank()) {
            result.text = "The AI connection is not configured in this build."
            return
        }
        val submittedImage = imageDataUrl
        val generation = ++requestGeneration
        setBusy(true)
        result.text = "Nemotron is analyzing the submitted context…"
        inference = lifecycleScope.launch {
            try {
                val context = client.analyze(submittedDescription, submittedImage)
                if (generation != requestGeneration) return@launch
                result.text = buildString {
                    append("AI-GENERATED CONTEXT\n\n")
                    append(context.summary)
                    append("\n\nOBSERVATIONS\n")
                    append(context.observations.joinToString("\n") { "• $it" }.ifEmpty { "No observations provided." })
                    append("\n\nUNCERTAINTIES\n")
                    append(context.uncertainties.joinToString("\n") { "• $it" }.ifEmpty { "No uncertainties were returned; this does not establish safety." })
                    append("\n\nThis summary has not sent, cancelled, or changed an alert.")
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                result.text = if (error is IllegalStateException) error.message else "The AI service could not be reached. Check the connection and try again."
            } finally { if (generation == requestGeneration) setBusy(false) }
        }
    }

    override fun onStop() {
        if (busy) {
            requestGeneration++
            inference?.cancel()
            client.cancel()
            setBusy(false)
            result.text = "Analysis cancelled because this screen was left."
        }
        super.onStop()
    }

    private fun setBusy(value: Boolean) {
        busy = value
        analyzeButton.isEnabled = !value
        imageButton.isEnabled = !value
        removeButton.isEnabled = !value
        description.isEnabled = !value
        consent.isEnabled = !value
    }

    private fun text(value: String, size: Int, bold: Boolean = false) = TextView(this).apply {
        text = value
        textSize = size.toFloat()
        setTextColor(Color.parseColor("#23463D"))
        setPadding(0, dp(8), 0, dp(12))
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun button(value: String, primary: Boolean, action: () -> Unit) = Button(this).apply {
        text = value
        isAllCaps = false
        minHeight = dp(52)
        setTextColor(Color.parseColor(if (primary) "#FFFFFF" else "#277B69"))
        background = GradientDrawable().apply {
            setColor(Color.parseColor(if (primary) "#277B69" else "#E5F1EB"))
            cornerRadius = dp(14).toFloat()
        }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) }
        setOnClickListener { action() }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
