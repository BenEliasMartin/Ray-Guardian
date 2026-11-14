package com.rayguardian.app

import android.content.Context
import android.util.AtomicFile
import android.util.Base64
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Signature
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Integration boundary for the live recorder, NOT a gallery/file signing utility.
 * prepare() is allowed only on a started hardware session with MockDeviceKit disabled.
 * The recorder must write outputFile, stop/release its muxer, then call onRecorderFinalized().
 * That callback takes NO file argument: it can seal only this attempt's owned output file.
 */
internal class LiveCaptureSeal private constructor(
    val outputFile: File,
    private val challenge: JSONObject,
    private val identity: AndroidCaptureIdentity.Enrollment,
    private val appContext: Context,
) {
    private val completed=AtomicBoolean(false)
    suspend fun onRecorderFinalized(): SealedCaptureUpload = withContext(Dispatchers.IO) {
        check(MockGlassesBridge.liveCaptureSealingAllowed(appContext)) { "Mock footage cannot receive a capture signature." }
        check(completed.compareAndSet(false,true)) { "This capture finalization was already handled. Retry the saved upload instead." }
        check(Files.isRegularFile(outputFile.toPath(),LinkOption.NOFOLLOW_LINKS) && outputFile.length() in 12..MAX_BYTES) { "No bounded finalized MP4 is available." }
        check(outputFile.canonicalFile.parentFile==outputFile.parentFile?.canonicalFile) { "Unexpected recording path." }
        // Nothing may transcode/fast-start/rewrite the original after the muxer closes.
        val digest=MessageDigest.getInstance("SHA-256")
        outputFile.inputStream().use { input ->
            val header=ByteArray(12);java.io.DataInputStream(input).readFully(header);check(String(header,4,4,Charsets.US_ASCII)=="ftyp") { "Recorder output is not an MP4." }
            digest.update(header)
            val buffer=ByteArray(64*1024);var total=12L
            while(true){val n=input.read(buffer);if(n<0)break;total+=n;check(total<=MAX_BYTES);digest.update(buffer,0,n)}
        }
        val videoHash=digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val receipt=CaptureReceipt.serialize(challenge.getString("incidentId"),identity.installationId,identity.keyId,challenge.getString("nonce"),videoHash)
        val store=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key=store.getEntry(identity.alias,null) as KeyStore.PrivateKeyEntry
        // The only signing call in the app: reachable through live finalization only.
        val signature=Signature.getInstance("SHA256withECDSA").run { initSign(key.privateKey);update(receipt);sign() }
        val artifact=SealedCaptureUpload(outputFile,challenge.getString("incidentId"),receipt,signature)
        artifact.persist()
        outputFile.setReadOnly()
        artifact
    }
    fun abort() { if(completed.compareAndSet(false,true))outputFile.delete() }
    companion object {
        const val MAX_BYTES=16L*1024*1024
        suspend fun prepare(context: Context, liveSession: DeviceSession, incidentId: String, api: AiClient): LiveCaptureSeal = withContext(Dispatchers.IO) {
            check(liveSession.state.value==DeviceSessionState.STARTED) { "A started live glasses session is required." }
            check(MockGlassesBridge.liveCaptureSealingAllowed(context)) { "Mock footage cannot receive a capture signature." }
            val identity=AndroidCaptureIdentity.enrollment(context)
            val challenge=api.createCaptureAttempt(identity,incidentId)
            check(challenge.getInt("version")==1 && challenge.getString("incidentId")==incidentId && challenge.getString("keyId")==identity.keyId && challenge.getString("installationId")==identity.installationId)
            // Validate all server fields before allocating an output file.
            CaptureReceipt.serialize(incidentId,identity.installationId,identity.keyId,challenge.getString("nonce"),"0".repeat(64))
            val directory=File(context.noBackupFilesDir,"live-sealed-captures").apply { check(mkdirs()||isDirectory) }
            directory.listFiles()?.filter { System.currentTimeMillis()-it.lastModified()>86_400_000 }?.forEach { it.delete() }
            val output=File(directory,sha256Hex(challenge.getString("nonce").toByteArray())+".mp4")
            check(output.createNewFile())
            LiveCaptureSeal(output,challenge,identity,context.applicationContext)
        }
    }
}

/** Durable retry uses the original receipt and signature. It never signs a file again. */
internal class SealedCaptureUpload internal constructor(
    val original: File,
    val incidentId: String,
    internal val receiptBytes: ByteArray,
    internal val signatureBytes: ByteArray,
) {
    internal fun persist() {
        val metadata=AtomicFile(File(original.path+".receipt"))
        val output=metadata.startWrite()
        try {
            output.write(JSONObject().put("incidentId",incidentId).put("receiptBase64",Base64.encodeToString(receiptBytes,Base64.NO_WRAP))
                .put("signatureBase64",Base64.encodeToString(signatureBytes,Base64.NO_WRAP)).toString().toByteArray(Charsets.UTF_8))
            metadata.finishWrite(output)
        }catch(error:Exception){metadata.failWrite(output);throw error}
    }
    suspend fun upload(api: AiClient): CaptureSealStatus = api.uploadSignedRecording(this)
    companion object {
        /** Only retrieves the app-owned signed outbox; not an import/signing path. */
        suspend fun pending(context: Context): List<SealedCaptureUpload> = withContext(Dispatchers.IO) {
            File(context.noBackupFilesDir,"live-sealed-captures").listFiles().orEmpty().filter { it.extension=="receipt" && System.currentTimeMillis()-it.lastModified()<86_400_000 }.mapNotNull { meta ->
                runCatching {
                    check(meta.length()<=8192)
                    val json=JSONObject(meta.readText())
                    val file=File(meta.path.removeSuffix(".receipt"))
                    check(file.isFile && file.length() in 12..LiveCaptureSeal.MAX_BYTES)
                    SealedCaptureUpload(file,json.getString("incidentId"),Base64.decode(json.getString("receiptBase64"),Base64.NO_WRAP),Base64.decode(json.getString("signatureBase64"),Base64.NO_WRAP))
                }.getOrNull()
            }
        }
    }
}
