package com.rayguardian.app

/** Version 1 is a flat, ASCII-only schema. These exact UTF-8 bytes are signed and uploaded. */
internal object CaptureReceipt {
    private val uuid = Regex("[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}")
    fun serialize(incidentId: String, installationId: String, keyId: String, nonce: String, videoSha256: String): ByteArray {
        require(uuid.matches(incidentId) && uuid.matches(installationId))
        require(Regex("p256_[a-f0-9]{64}").matches(keyId))
        require(Regex("[A-Za-z0-9_-]{43}").matches(nonce))
        require(Regex("[a-f0-9]{64}").matches(videoSha256))
        return "{\"version\":1,\"incidentId\":\"$incidentId\",\"keyId\":\"$keyId\",\"installationId\":\"$installationId\",\"nonce\":\"$nonce\",\"videoSha256\":\"$videoSha256\"}".toByteArray(Charsets.UTF_8)
    }
}

internal enum class CaptureSealStatus(val label: String, val seal: String? = null) {
    MATCHES("Matches signed recording", "Signed by the capture app"),
    FILE_DIFFERS("File differs from signed recording"),
    UNTRUSTED("No trusted capture signature");
    companion object {
        fun fromWire(value: String): CaptureSealStatus = when(value) {
            "matches" -> MATCHES
            "file_differs" -> FILE_DIFFERS
            else -> UNTRUSTED
        }
    }
}
