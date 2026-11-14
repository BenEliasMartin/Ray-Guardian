package com.rayguardian.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.app.AlertDialog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Existing incident screens can display only a backend-verified seal, never a local signing claim. */
internal class CaptureSealPanel(context: Context, private val scope: CoroutineScope, private val incidentId: () -> String?) : LinearLayout(context) {
    private val status=TextView(context).apply { text=CaptureSealStatus.UNTRUSTED.label;textSize=13f }
    private val seal=TextView(context).apply { textSize=14f;visibility=GONE }
    private val api=AiClient()
    init {
        orientation=VERTICAL
        addView(TextView(context).apply { text="Recording verification";textSize=15f })
        addView(seal);addView(status)
        addView(TextView(context).apply { text="The seal checks file integrity against the enrolled app’s signature. It does not prove what happened in the scene.";textSize=12f })
        addView(Button(context).apply {
            text="Check recording signature";isAllCaps=false
            setOnClickListener {
                val id=incidentId()
                if(id==null){show(CaptureSealStatus.UNTRUSTED);return@setOnClickListener}
                isEnabled=false
                scope.launch {
                    try { val result=api.captureSealStatus(id);if(incidentId()==id)show(result) }
                    catch(error:Exception){if(error is CancellationException)throw error;seal.visibility=GONE;status.text="Verification unavailable · no seal confirmed"}
                    finally{isEnabled=true}
                }
            }
        })
    }
    fun show(value: CaptureSealStatus) {
        status.text=value.label
        seal.text=value.seal.orEmpty();seal.visibility=if(value.seal==null)GONE else VISIBLE
    }
    override fun onDetachedFromWindow(){api.cancel();super.onDetachedFromWindow()}
}

internal fun showCaptureKeyEnrollment(context: Context, scope: CoroutineScope) {
    scope.launch {
        try {
            val json=withContext(Dispatchers.IO) { AndroidCaptureIdentity.enrollment(context).json().toString(2) }
            AlertDialog.Builder(context).setTitle("Enroll this capture app installation")
                .setMessage("Give this public key to the backend administrator. This does not enroll the key automatically.\n\n$json")
                .setPositiveButton("Copy public enrollment") { _,_ ->
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Capture key enrollment",json))
                }.setNegativeButton("Close",null).show()
        }catch(error:Exception){if(error is CancellationException)throw error;AlertDialog.Builder(context).setMessage("Could not prepare the Android Keystore signing key.").setPositiveButton("Close",null).show()}
    }
}
