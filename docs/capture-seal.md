# Capture seal integration handoff

Status: the seal module, enrollment, verifier, upload transport and incident-view component are implemented. The MP4 recorder is being implemented separately. **No current capture flow calls the signing callback yet.** Live recording end-to-end verification is pending that connection and testing on the demo Android phone.

The animations are saved locally in `design/hackathon-motion/` and `design/ray-guardian-hackathon-motion.zip`; they are not part of this feature branch’s committed changes.

## Claim and limits

Use **“Signed by the capture app.”** A successful seal says **“Matches signed recording.”** It means the received original MP4 matches the bytes signed by the enrolled installation. It does not establish that a crime, collapse or other event occurred, identify the wearer, or prove the camera’s sensor provenance. This prototype trusts the phone’s capture path. Footage injected before signing on a compromised phone is outside this guarantee. Keystore usage is not remote attestation.

## Phone enrollment: one admin action

1. Install the Android app. In the existing **Live glasses** screen, choose **Capture signing key · admin enrollment** and copy the public enrollment JSON. This generates an installation-specific P-256 key using `AndroidKeyStore`, signing purpose and SHA-256. The private key never leaves the Keystore. Installation identity, recorder outputs and retry receipts use the app’s private, non-backed-up storage.
2. Save that public JSON as `phone-public-key.json` on the backend host. Verify it came from the intended demo phone. This is an administrative trust decision; possession of the normal client bearer token cannot enroll a key.
3. From the repo root, using the backend’s existing persistent database, encryption key and client token:

   ```sh
   node --env-file=.env server/enroll-capture-key.mjs phone-public-key.json
   ```

   For the existing Docker image, use `docker compose exec -T api node enroll-capture-key.mjs - < phone-public-key.json` (include your normal Compose override flags). The running backend reads the same SQLite database; no restart is required. No admin secret is embedded in the APK or accepted by the upload endpoint.
4. The returned `keyId` is `p256_` plus the SHA-256 fingerprint of the X.509 SPKI public key. Enrollment binds this to `installationId` and the authenticated backend owner. Existing enrollment is immutable; a new key cannot silently replace it. A reinstall generates a new installation and requires enrollment again. A registry entry can be revoked administratively by setting its encrypted `capture_key.revoked` field; a dedicated rotation/revocation UI is not included.

An ephemeral development backend cannot share enrollment with a separate CLI process. Configure `DATA_ENCRYPTION_KEY` and the same `DATA_PATH` for both processes. The existing persistent Docker volume meets this requirement.

## Recorder hook: the remaining connection

Use the existing incident ID for the entire capture, upload and incident view. `MainActivity.liveIncidentId` already exists. `LiveGlassesActivity.recordingIncidentId` is now allocated when a diagnostic capture starts and reused by its later simulated dispatch. The backend nonce binds a single capture attempt even though these Android IDs are created on the phone.

Only add the following calls in the **real live glasses recorder**. Never call them from gallery import, video replay, MockDeviceKit, a file-picker handler, or an upload handler.

```kotlin
// After the real DAT session reaches STARTED; before opening the recorder.
// Use a separate AiClient so seal networking cannot cancel SOS/dispatch requests.
val sealApi = AiClient()
val seal = LiveCaptureSeal.prepare(context, deviceSession, incidentId, sealApi)

// Configure the existing recorder/muxer to WRITE DIRECTLY TO seal.outputFile.
// Keep the existing event trigger, duration limit and recording/upload consent.
// Do not copy a gallery file into it. There is deliberately no sealFile(file) API.

// In the recorder's SUCCESS callback, AFTER stop/release has closed the MP4:
val pending = seal.onRecorderFinalized()
// That callback hashes the finalized original and signs immediately, before upload.
// It takes no path argument and can run only once for this capture attempt.

// Upload asynchronously. Failure must not stop or delay check-in/SOS delivery.
val verified = pending.upload(sealApi)
captureSealPanel.show(verified) // only for the same incident still being displayed

// If the recorder aborts or finalization fails, call seal.abort(); show no seal.
// A lost upload response must retry pending.upload(), not call finalization again.
```

The callback is already implemented. It checks the owned private output path, regular-file status, MP4 header and 16 MiB bound; hashes exact file bytes with SHA-256; serializes the receipt once to UTF-8; signs those bytes using `SHA256withECDSA`; and durably saves the original receipt/signature for retries. There is no generic file-signing endpoint or gallery signer. The signing entry requires a started DAT session with MockDeviceKit disabled and checks the mock gate again on finalization. This gate still relies on correctly wiring the callback exclusively to the hardware recorder, as the stated prototype guarantee requires.

Do not sign a partial, cancelled, mock or imported recording. Do not sign again during retry. If a playback preview is needed, write it to a separate file **after signing** and always upload/retain `pending.original` for verification. Do not fast-start, remux, compress or edit that original after finalization.

If challenge issuance or signing fails, continue the normal incident/SOS flow with **No trusted capture signature**. Keep camera recording event-driven and bounded; this module starts no camera, background recorder, microphone, or periodic upload.

`SealedCaptureUpload.pending(context)` loads previously signed, private outbox artifacts without generating signatures. `pending.upload(api)` retries the same bytes. Local originals/receipts are eligible for removal after 24 hours and are pruned on the next prepared capture. Add lifecycle cleanup if the recorder needs immediate deletion; no successful verification requires saving a preview.

## Upload contract

Because newest main contains neither a finalized-MP4 upload endpoint nor its recorder, this feature adds the bounded recording subresource below. Your colleague can call this transport from the existing upload workflow, or reuse `CaptureSealService.accept()` in his endpoint. **Do not create another signer on the backend.**

All routes require the existing client bearer token. Browser-origin requests remain blocked. Public keys supplied with uploads are ignored and cannot establish trust.

| Request | Body / result |
| --- | --- |
| `POST /v1/capture-attempts` | JSON `{keyId, installationId, incidentId}`; returns `{version, incidentId, keyId, installationId, nonce, expiresAt}`. Omit `incidentId` only if a server-assigned ID is desired. Nonce expires in five minutes and is single-use on acceptance. |
| `POST /v1/incidents/:id/recording` | Raw original MP4 body, `Content-Type: video/mp4`, maximum 16 MiB. `X-Guardian-Receipt` is standard base64 of the exact UTF-8 receipt bytes; `X-Guardian-Signature` is standard base64 of the DER ECDSA signature. The file, receipt and signature travel in one request. |
| `GET /v1/incidents/:id/recording` | Backend verification result, or `No trusted capture signature`. |
| `GET /v1/incidents/:id/recording/original` | The authenticated, byte-for-byte original MP4; never a generated preview. |
| `DELETE /v1/incidents/:id/recording` | Deletes original, accepted receipt and capture attempts. |

Receipt v1 contains exactly:

```json
{"version":1,"incidentId":"UUID","keyId":"p256_SHA256_OF_SPKI","installationId":"UUID","nonce":"SERVER_NONCE","videoSha256":"SHA256_OF_FINALIZED_MP4"}
```

The JSON string is serialized **once** on Android. The backend verifies the received receipt bytes with `crypto.verify('sha256', originalReceiptBytes, {key: enrolledKey, dsaEncoding:'der'}, signature)`; it does not reserialize parsed JSON for signature verification. It looks up the registered public key, checks installation/owner/incident/nonce binding, and hashes the received file before accepting.

Matching original bytes, accepted receipt/signature, result and nonce consumption are saved in a single SQLite `BEGIN IMMEDIATE` transaction. The original is an AES-256-GCM encrypted BLOB in `capture_originals`; exact receipt and signature bytes are retained as base64 inside encrypted metadata. The first accepted upload is immutable. Identical retries return the stored result, including after the five-minute nonce expires; another signed receipt/file cannot replace it. Invalid uploads never overwrite a previous acceptance.

Accepted files and receipts expire after 24 hours. The existing maintenance timer purges expired originals. Deleting a Guardian incident also deletes its capture if present. No public signed download URL is created. This is an explicit exception to the previous metadata-only persistence behavior: only **accepted signed originals**, submitted through this opt-in capture workflow, are retained. Untrusted/mismatched bytes are not persisted.

## Existing incident view

`CaptureSealPanel` is attached to the current Android incident views. It begins with **No trusted capture signature** and queries the backend when **Check recording signature** is pressed. Only a backend `matches` result displays **Signed by the capture app**. Local signing, upload start, a generated preview, unknown statuses and verification errors never create that label. The recorder integration should pass an upload result to the panel only while that same incident remains on screen; reset it when incident identity changes.

## Validation

Backend tests cover exact original and original receipt-byte retention, edited files, unknown/incorrect keys, wrong incident/installation/nonce/owner, nonce expiry, revocation, immutable enrollment, identical/concurrent retries, replacement rejection, database rollback, restart persistence, retention/deletion, upload authentication and independent simulated SOS. A Java-generated P-256/SPKI/DER receipt fixture also verifies with Node, checking interoperability of the JCA algorithm used on Android. Android unit tests check the exact receipt format, ECDSA signing/verification and that only the verified status gets a seal label. Debug/Release compilation and Android lint check the prepared adapter.

Physical acceptance is still pending your colleague’s recorder:

| Scenario | Expected |
| --- | --- |
| Enrolled phone → live recorder → finalization → upload | **Matches signed recording**, **Signed by the capture app** |
| Edited original with unchanged receipt/signature | **File differs from signed recording** |
| Gallery/mock/lookalike with no trusted receipt, or unknown key | **No trusted capture signature** |
| Valid receipt submitted under another incident | HTTP 409 rejection |
| Retry same original/receipt/signature | Same result, one stored original |
| Any seal/network/storage error while SOS is used | Existing SOS flow continues independently |
