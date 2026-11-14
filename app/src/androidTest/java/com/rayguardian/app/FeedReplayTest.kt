package com.rayguardian.app

import android.content.Intent
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiScrollable
import androidx.test.uiautomator.UiSelector
import androidx.test.uiautomator.Until
import java.util.regex.Pattern
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeedReplayTest {
    @Test fun replayRendersStopsForHeatAndHandsOffAFrameWithoutUploading() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = UiDevice.getInstance(instrumentation)
        Configurator.getInstance().waitForIdleTimeout = 0
        val intent = Intent(instrumentation.targetContext, MainActivity::class.java)
            .putExtra("ray_guardian_simulator", true)
            .putExtra("ray_guardian_feed", true)
        ActivityScenario.launch<MainActivity>(intent).use {
            fun waitForFrames() {
                val frames = By.text(Pattern.compile("Frames received: [1-9][0-9]* · presented: [1-9][0-9]*.*"))
                assertNotNull("No frames were presented by TextureView", device.wait(Until.findObject(frames), 20_000))
            }
            fun click(text: String) {
                UiScrollable(UiSelector().scrollable(true)).scrollIntoView(UiSelector().text(text))
                val control = device.wait(Until.findObject(By.text(text)), 5000)
                assertNotNull("Missing control: $text", control)
                control.click()
            }
            waitForFrames()
            click("Stop feed")
            assertNotNull(device.wait(Until.findObject(By.textContains("Feed stopped by you")), 5000))
            SystemClock.sleep(500)
            click("Start replay")
            waitForFrames()
            click("Simulate hot glasses")
            assertNotNull(device.wait(Until.findObject(By.textContains("Feed stopped for heat")), 5000))
            click("Reset simulated heat")
            SystemClock.sleep(500)
            click("Start replay")
            waitForFrames()
            click("Analyze current frame with Nemotron")
            assertNotNull(device.wait(Until.findObject(By.textContains("Frozen simulator frame")), 8000))
            val consent = device.wait(Until.findObject(By.clazz("android.widget.CheckBox")), 5000)
            assertNotNull(consent)
            assertFalse("Frame handoff must not grant upload consent", consent.isChecked)
            // Never press Analyze: this test uses only the bundled synthetic clip and no provider calls.
            device.pressHome()
        }
    }
}
