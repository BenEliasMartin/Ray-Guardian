package com.rayguardian.app

import android.os.SystemClock
import android.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Foreground-only owner of capture, ephemeral media, optional requests, and teardown. */
class TriggerRuntime(
    private val scope: CoroutineScope,
    budget: TriggerController.CaptureBudget,
    private val onIncident: (TriggerController.Signal) -> Unit,
    private val onChanged: () -> Unit,
) {
    val controller = TriggerController(budget)
    private val frames = TransientFrames()
    private val capture = GlassesContextCapture(scope)
    private val client = AiClient()
    private var ticker: Job? = null
    private var analysis: Job? = null
    private var foreground = false
    private var pendingSimulation = false
    private var pendingSignal = TriggerController.Signal.MANUAL_SOS
    private var contextSimulation = false
    private var contextSignal = TriggerController.Signal.MANUAL_SOS
    var assessment: String? = null; private set
    val retainedFrames get() = frames.size

    fun resume() {
        foreground = true
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive && foreground) {
                val before = controller.phase to controller.reason
                execute(controller.tick(SystemClock.elapsedRealtime()))
                if (before != (controller.phase to controller.reason)) onChanged()
                delay(250)
            }
        }
    }

    fun pause() {
        foreground = false
        ticker?.cancel()
        ticker = null
        disarm()
    }

    fun configure(settings: TriggerController.Settings) {
        assessment = null
        execute(controller.configure(settings))
        onChanged()
    }

    fun availability(value: TriggerController.Availability) {
        val previous = controller.phase to controller.reason
        execute(controller.setAvailability(value))
        if (previous != (controller.phase to controller.reason)) {
            assessment = null
            onChanged()
        }
    }

    fun arm() {
        if (!foreground) return
        assessment = null
        execute(controller.arm(SystemClock.elapsedRealtime()))
        onChanged()
    }

    fun disarm() {
        assessment = null
        execute(controller.disarm())
        onChanged()
    }

    fun cancel() {
        assessment = null
        execute(controller.cancelContext())
        onChanged()
    }

    fun offer(signal: TriggerController.Signal, simulated: Boolean) {
        if (!foreground) return
        pendingSimulation = simulated
        pendingSignal = signal
        execute(controller.offer(signal, SystemClock.elapsedRealtime()))
        onChanged()
    }

    private fun execute(effects: List<TriggerController.Effect>) {
        effects.forEach { effect ->
            when (effect) {
                is TriggerController.Effect.Incident -> onIncident(effect.signal)
                is TriggerController.Effect.StartCapture -> {
                    assessment = null
                    contextSimulation = pendingSimulation
                    contextSignal = pendingSignal
                    val id = effect.token
                    capture.start(contextSimulation, onFrame = { bytes ->
                        val now = SystemClock.elapsedRealtime()
                        if (!foreground || !controller.frameReceived(id, now)) bytes.fill(0)
                        else if (frames.add(bytes)) onChanged()
                    }, onFailure = {
                        execute(controller.captureFailed(id))
                        onChanged()
                    })
                }
                is TriggerController.Effect.StopCapture -> {
                    capture.stop()
                    assessment = "${frames.size} context frames received. Capture stopped; no emergency determination was made."
                }
                is TriggerController.Effect.Analyze -> beginAnalysis(effect.token)
                TriggerController.Effect.CancelAnalysis -> { analysis?.cancel(); analysis = null; client.cancel() }
                TriggerController.Effect.ClearContext -> { frames.clear(); assessment = null }
            }
        }
    }

    private fun authorized(id: Long) = foreground && controller.phase == TriggerController.Phase.ANALYZING &&
        controller.token == id && controller.settings.cameraContext && controller.settings.cloudContext

    private fun beginAnalysis(id: Long) {
        if (!authorized(id)) return
        val copies = frames.copies()
        // Drop originals before waiting on network. Copies are cleared after encoding, including on cancellation.
        frames.clear()
        analysis = scope.launch {
            try {
                val jpeg = try { withContext(Dispatchers.Default) { GlassesContextCapture.montage(copies) } }
                    finally { copies.forEach { it.fill(0) } }
                val image = try { "data:image/jpeg;base64," + Base64.encodeToString(jpeg, Base64.NO_WRAP) }
                    finally { jpeg.fill(0) }
                if (!authorized(id)) return@launch
                val description = "${if (contextSimulation) "SIMULATED context, not a real emergency." else "Wearer-triggered context."} " +
                    "Reported trigger: ${contextSignal.name}. The image shows ordered frames captured AFTER activation. " +
                    "No pre-event video exists. The trigger is unvalidated and does not establish a fall, assault, or medical condition. " +
                    "No contacts or responders have been notified. Summarize visible observations and uncertainty."
                val result = client.analyze(description, image)
                if (authorized(id)) {
                    execute(controller.analysisFinished(id))
                    assessment = "AI-GENERATED CONTEXT\n${result.summary}\n\n" +
                        "Uncertainties: ${result.uncertainties.joinToString("; ")}\n\nThis advisory has not changed any alert."
                    onChanged()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (authorized(id)) {
                    execute(controller.analysisFinished(id))
                    assessment = "Optional AI context unavailable. Temporary images cleared; incident flow continues."
                    onChanged()
                }
            }
        }
    }
}
