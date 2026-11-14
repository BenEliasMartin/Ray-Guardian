package com.rayguardian.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import org.json.JSONObject

/** Public enrollment information only. This class deliberately exposes no sign-file API. */
internal object AndroidCaptureIdentity {
    data class Enrollment(val installationId: String, val keyId: String, val publicKeySpki: String) {
        fun json(): JSONObject = JSONObject().put("installationId",installationId).put("keyId",keyId).put("publicKeySpki",publicKeySpki)
        val alias: String get() = "rayguardian.capture.v1.$installationId"
    }
    @Synchronized fun enrollment(context: Context): Enrollment {
        val identity = AtomicFile(File(context.noBackupFilesDir,"capture-installation-id"))
        val installationId = if(identity.baseFile.exists()) identity.openRead().bufferedReader().use { it.readText() }
            else UUID.randomUUID().toString().also { value ->
                val output=identity.startWrite()
                try { output.write(value.toByteArray(Charsets.UTF_8));identity.finishWrite(output) }
                catch(error:Exception) { identity.failWrite(output);throw error }
            }
        check(runCatching { UUID.fromString(installationId).toString()==installationId }.getOrDefault(false)) { "Capture installation identity is invalid." }
        val alias="rayguardian.capture.v1.$installationId"
        val store=KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if(!store.containsAlias(alias)) {
            val generator=KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,"AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256).build())
            generator.generateKeyPair()
        }
        val spki=checkNotNull(store.getCertificate(alias)).publicKey.encoded
        return Enrollment(installationId,"p256_"+sha256Hex(spki),Base64.encodeToString(spki,Base64.NO_WRAP))
    }
}
internal fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
