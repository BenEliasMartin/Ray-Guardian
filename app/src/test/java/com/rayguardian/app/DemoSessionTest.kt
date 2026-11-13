package com.rayguardian.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DemoSessionTest {
    @Test fun manualSosOnlyWorksAfterArmingAndSkipsCheckIn() {
        val session = DemoSession()
        session.manualSos()
        assertEquals(DemoSession.Phase.DISARMED, session.phase)
        session.arm()
        session.manualSos()
        assertEquals(DemoSession.Phase.ALERT, session.phase)
        assertEquals(DemoSession.Trigger.MANUAL, session.trigger)
        assertNull(session.deadlineMillis)
    }

    @Test fun replayEscalatesOnlyAfterDeadline() {
        val session = DemoSession()
        session.arm()
        session.replayCandidate(1000)
        session.tick(15_999)
        assertEquals(DemoSession.Phase.CHECK_IN, session.phase)
        session.tick(16_000)
        assertEquals(DemoSession.Phase.ALERT, session.phase)
        assertEquals(DemoSession.Trigger.REPLAYED_CANDIDATE, session.trigger)
    }

    @Test fun cancellationAndDisarmingClearPendingCountdown() {
        val session = DemoSession()
        session.arm()
        session.replayCandidate(0)
        session.cancel()
        session.tick(20_000)
        assertEquals(DemoSession.Phase.ARMED, session.phase)
        assertNull(session.deadlineMillis)
        session.replayCandidate(30_000)
        session.disarm()
        session.tick(50_000)
        assertEquals(DemoSession.Phase.DISARMED, session.phase)
    }

    @Test fun manualSosOverridesCheckInAndCancelledAlertCanBeFinished() {
        val session = DemoSession()
        session.arm()
        session.replayCandidate(0)
        session.manualSos()
        session.cancel()
        assertEquals(DemoSession.Phase.CANCELLED, session.phase)
        session.tick(20_000)
        assertEquals(DemoSession.Phase.CANCELLED, session.phase)
        session.finish()
        assertEquals(DemoSession.Phase.DISARMED, session.phase)
    }

    @Test fun acknowledgmentIsOnlyPossibleForAnOpenSimulatedAlert() {
        val session = DemoSession()
        session.acknowledge()
        assertEquals(DemoSession.Phase.DISARMED, session.phase)
        session.arm()
        session.manualSos()
        session.acknowledge()
        assertEquals(DemoSession.Phase.ACKNOWLEDGED, session.phase)
        session.cancel()
        assertEquals(DemoSession.Phase.CANCELLED, session.phase)
        session.finish()
        assertEquals(DemoSession.Phase.DISARMED, session.phase)
    }
}
