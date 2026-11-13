package com.rayguardian.app

import android.content.Context
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel

/** Available only in debug builds; never substitute these states for a real device. */
object MockGlassesBridge {
    val available = true

    suspend fun start(context: Context): String? {
        val kit = MockDeviceKit.getInstance(context.applicationContext)
        kit.enable()
        var failure: String? = null
        kit.pairGlasses(GlassesModel.RAYBAN_META).fold(
            onSuccess = { device ->
                device.powerOn()
                device.unfold()
                device.don()
            },
            onFailure = { error, _ -> failure = error.description },
        )
        return failure
    }
}
