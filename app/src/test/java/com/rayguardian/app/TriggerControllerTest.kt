package com.rayguardian.app

import org.junit.Assert.*
import org.junit.Test

class TriggerControllerTest {
    private val ready = TriggerController.Availability(true, true, true)
    private fun armed(camera: Boolean = true, cloud: Boolean = false, budget: TriggerController.CaptureBudget = TriggerController.CaptureBudget()): TriggerController {
        return TriggerController(budget).apply {
            configure(TriggerController.Settings(TriggerController.Signal.entries.toSet(), camera, cloud))
            setAvailability(ready)
            arm(0)
        }
    }
    private fun List<TriggerController.Effect>.starts() = filterIsInstance<TriggerController.Effect.StartCapture>()

    @Test fun standbyAndDisarmedInputsNeverStartCapture() {
        val c = TriggerController()
        assertTrue(c.offer(TriggerController.Signal.MANUAL_SOS, 0).isEmpty())
        c.arm(0)
        assertTrue(c.tick(1000).starts().isEmpty())
        assertEquals(TriggerController.Phase.STANDBY, c.phase)
    }

    @Test fun manualSosCreatesIncidentWithoutCameraOrCloudConsent() {
        val c = armed(camera = false, cloud = false)
        val effects = c.offer(TriggerController.Signal.MANUAL_SOS, 1)
        assertEquals(1, effects.filterIsInstance<TriggerController.Effect.Incident>().size)
        assertTrue(effects.starts().isEmpty())
        assertFalse(effects.any { it is TriggerController.Effect.Analyze })
    }

    @Test fun shoutingAloneNeverCapturesOrCreatesIncidentEvenWhenEnabled() {
        val c = armed(cloud = true)
        repeat(20) { assertTrue(c.offer(TriggerController.Signal.LOUD_VOICE, it.toLong()).isEmpty()) }
        assertEquals(TriggerController.Phase.STANDBY, c.phase)
    }

    @Test fun loudHintDuringCaptureCannotHideTheActiveCaptureState() {
        val c=armed()
        c.offer(TriggerController.Signal.MANUAL_SOS,0)
        val reason=c.reason
        assertTrue(c.offer(TriggerController.Signal.LOUD_VOICE,100).isEmpty())
        assertEquals(TriggerController.Phase.CAPTURING,c.phase)
        assertEquals(reason,c.reason)
    }

    @Test fun disabledFutureAndStaleTriggersAreRejected() {
        val c = armed()
        assertTrue(c.offer(TriggerController.Signal.FALL_CANDIDATE, 6000, 0).isEmpty())
        assertTrue(c.offer(TriggerController.Signal.FALL_CANDIDATE, 6000, 6001).isEmpty())
        c.configure(TriggerController.Settings(enabled = emptySet(), cameraContext = true))
        c.arm(6000)
        assertTrue(c.offer(TriggerController.Signal.FALL_CANDIDATE, 6001).isEmpty())
    }

    @Test fun noPermissionNoDeviceAndUnknownThermalBlockOnlyCapture() {
        listOf(TriggerController.Availability(false,true,true), TriggerController.Availability(true,false,true), TriggerController.Availability(true,true,false))
            .forEach { gate ->
                val c = armed()
                c.setAvailability(gate)
                val effects = c.offer(TriggerController.Signal.MANUAL_SOS, 1)
                assertEquals(1, effects.filterIsInstance<TriggerController.Effect.Incident>().size)
                assertTrue(effects.starts().isEmpty())
            }
    }

    @Test fun captureStopsAtHardDeadlineAndNoCloudConsentMeansClearFrames() {
        val c = armed()
        val id = c.offer(TriggerController.Signal.FALL_CANDIDATE, 0).starts().single().token
        assertTrue(c.frameReceived(id, 100))
        assertTrue(c.tick(7999).isEmpty())
        val end = c.tick(8000)
        assertEquals(1, end.filterIsInstance<TriggerController.Effect.StopCapture>().size)
        assertTrue(end.contains(TriggerController.Effect.ClearContext))
        assertFalse(end.any { it is TriggerController.Effect.Analyze })
        assertEquals("Camera off; frames discarded locally, no cloud submission",c.reason)
        assertFalse(c.frameReceived(id,8000))
    }

    @Test fun noUsableFramesMeansNoCloudRequestEvenWithConsent() {
        val c = armed(cloud = true)
        c.offer(TriggerController.Signal.MANUAL_SOS,0)
        assertFalse(c.tick(8000).any { it is TriggerController.Effect.Analyze })
    }

    @Test fun cloudStartsOnlyAfterCaptureStopsAndHasIndependentTimeout() {
        val c = armed(cloud = true)
        val id = c.offer(TriggerController.Signal.MANUAL_SOS,0).starts().single().token
        c.frameReceived(id,100)
        val effects = c.tick(8000)
        assertTrue(effects.first() is TriggerController.Effect.StopCapture)
        assertTrue(effects.last() is TriggerController.Effect.Analyze)
        assertEquals(TriggerController.Phase.ANALYZING,c.phase)
        val timeout = c.tick(8000 + TriggerController.ANALYSIS_MILLIS)
        assertTrue(timeout.contains(TriggerController.Effect.CancelAnalysis))
        assertTrue(timeout.contains(TriggerController.Effect.ClearContext))
    }

    @Test fun consentRevocationStopsCaptureAndRequiresExplicitRearm() {
        val c = armed(cloud = true)
        c.offer(TriggerController.Signal.MANUAL_SOS,0)
        val revoke = c.configure(c.settings.copy(cameraContext = false))
        assertTrue(revoke.any { it is TriggerController.Effect.StopCapture })
        assertTrue(revoke.contains(TriggerController.Effect.ClearContext))
        assertFalse(c.armed)
        assertTrue(c.offer(TriggerController.Signal.MANUAL_SOS,1).isEmpty())
    }

    @Test fun cloudRevocationCancelsInflightRequestAndRejectsLateResults() {
        val c = armed(cloud = true)
        val id = c.offer(TriggerController.Signal.MANUAL_SOS,0).starts().single().token
        c.frameReceived(id,100)
        c.tick(8000)
        val effects = c.configure(c.settings.copy(cloudContext=false))
        assertTrue(effects.contains(TriggerController.Effect.CancelAnalysis))
        assertTrue(c.analysisFinished(id).isEmpty())
        assertFalse(c.armed)
    }

    @Test fun availabilityLossStopsCaptureAndRestorationNeverRestartsIt() {
        val c = armed()
        c.offer(TriggerController.Signal.MANUAL_SOS,0)
        assertTrue(c.setAvailability(TriggerController.Availability()).any { it is TriggerController.Effect.StopCapture })
        assertTrue(c.setAvailability(ready).isEmpty())
        assertTrue(c.tick(1000).starts().isEmpty())
    }

    @Test fun disarmDuringCaptureAndAnalysisClearsAndIgnoresLateCallbacks() {
        val c = armed(cloud=true)
        val old = c.offer(TriggerController.Signal.MANUAL_SOS,0).starts().single().token
        assertTrue(c.disarm().any { it is TriggerController.Effect.StopCapture })
        assertFalse(c.frameReceived(old,1))
        c.arm(60000)
        val fresh = c.offer(TriggerController.Signal.MANUAL_SOS,60000).starts().single().token
        assertNotEquals(old,fresh)
        c.frameReceived(fresh,60001)
        c.tick(68000)
        assertTrue(c.disarm().contains(TriggerController.Effect.CancelAnalysis))
        assertTrue(c.analysisFinished(fresh).isEmpty())
    }

    @Test fun intentionalSosBypassesIncidentCooldownButNotCaptureCooldown() {
        val c = armed()
        c.offer(TriggerController.Signal.FALL_CANDIDATE,0)
        c.tick(8000)
        assertTrue(c.offer(TriggerController.Signal.HEART_RATE,9000).isEmpty())
        val sos = c.offer(TriggerController.Signal.VOICE_SOS,9000)
        assertEquals(1,sos.filterIsInstance<TriggerController.Effect.Incident>().size)
        assertTrue(sos.starts().isEmpty())
    }

    @Test fun manualSosDuringCaptureCreatesNoSecondWindowOrEarlyCloudCall() {
        val c=armed(cloud=true)
        val first=c.offer(TriggerController.Signal.FALL_CANDIDATE,0).starts().single().token
        val sos=c.offer(TriggerController.Signal.MANUAL_SOS,100)
        assertEquals(1,sos.filterIsInstance<TriggerController.Effect.Incident>().size)
        assertTrue(sos.starts().isEmpty())
        assertFalse(sos.any { it is TriggerController.Effect.Analyze })
        assertEquals(first,c.token)
    }

    @Test fun cumulativeBudgetSurvivesDisarmAndBlocksBurstStormsWithoutBlockingSos() {
        val budget = TriggerController.CaptureBudget()
        repeat(3) { index ->
            val c = armed(budget=budget)
            val now = index * 60_000L
            assertEquals(1,c.offer(TriggerController.Signal.MANUAL_SOS,now).starts().size)
            c.disarm()
        }
        val c = armed(budget=budget)
        val blocked = c.offer(TriggerController.Signal.MANUAL_SOS,180000)
        assertEquals(1,blocked.filterIsInstance<TriggerController.Effect.Incident>().size)
        assertTrue(blocked.starts().isEmpty())
        assertEquals(1,c.offer(TriggerController.Signal.MANUAL_SOS,600000).starts().size)
    }

    @Test fun expiryStopsWorkAndClockRegressionDoesNotExtendCapture() {
        val c = armed()
        c.tick(100)
        assertTrue(c.offer(TriggerController.Signal.MANUAL_SOS,50).isEmpty())
        c.offer(TriggerController.Signal.MANUAL_SOS,TriggerController.ARM_MILLIS-1)
        val effects=c.tick(TriggerController.ARM_MILLIS)
        assertTrue(effects.any { it is TriggerController.Effect.StopCapture })
        assertFalse(c.armed)
    }
}
