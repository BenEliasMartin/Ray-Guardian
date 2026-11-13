package com.rayguardian.app

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid

/** A foreground-only stream of smartwatch heart-rate readings. All callbacks arrive on the main thread. */
interface HeartRateSource {
    interface Listener {
        fun onSample(bpm: Int, skinContact: Boolean?)
        fun onStatus(status: String)
    }

    val label: String
    fun start(listener: Listener)
    fun stop()
}

/** Replays a scripted heart-rate trace at 1 Hz. It reads no sensor and is for rehearsal only. */
class SimulatedWatchSource(private val scenario: SimulatedHeartRateTrace.Scenario) : HeartRateSource {
    override val label = "Simulated watch — ${scenario.title.lowercase()}"
    private val handler = Handler(Looper.getMainLooper())
    private var listener: HeartRateSource.Listener? = null
    private var second = 0

    private val emit = object : Runnable {
        override fun run() {
            val target = listener ?: return
            val bpm = SimulatedHeartRateTrace.bpmAt(scenario, second)
            if (bpm != null) target.onSample(bpm, true)
            else if (second == SimulatedHeartRateTrace.WATCH_REMOVED_AT) target.onStatus("Simulated watch stopped reporting")
            second++
            handler.postDelayed(this, 1_000L)
        }
    }

    override fun start(listener: HeartRateSource.Listener) {
        stop()
        this.listener = listener
        second = 0
        listener.onStatus("Replaying: ${scenario.title}")
        handler.post(emit)
    }

    override fun stop() {
        listener = null
        handler.removeCallbacks(emit)
    }
}

/**
 * Connects to the first nearby device advertising the standard Bluetooth Heart Rate service (0x180D),
 * such as a watch in heart-rate broadcast mode or a chest strap. Requires BLUETOOTH_SCAN and
 * BLUETOOTH_CONNECT, which the caller must have granted before [start].
 */
@SuppressLint("MissingPermission")
class BleHeartRateSource(context: Context) : HeartRateSource {
    override val label = "Bluetooth heart-rate device"
    private val appContext = context.applicationContext
    private val adapter = appContext.getSystemService(BluetoothManager::class.java)?.adapter
    private val handler = Handler(Looper.getMainLooper())
    private var listener: HeartRateSource.Listener? = null
    private var gatt: BluetoothGatt? = null
    private var scanning = false

    private val scanTimeout = Runnable {
        if (scanning) {
            stopScan()
            listener?.onStatus("No heart-rate device found. Enable heart-rate broadcast on your watch and try again.")
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!scanning) return
            stopScan()
            connect(result.device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            post { onStatus("Bluetooth scan failed (code $errorCode)") }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            // No identity check here: this can arrive before connectGatt() has returned. Closed
            // connections receive no further callbacks.
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    post { onStatus("Connected, looking for heart-rate data…") }
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> post { onStatus("Heart-rate device disconnected") }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (g !== gatt) return
            val characteristic = g.getService(HeartRateMeasurement.SERVICE_UUID)
                ?.getCharacteristic(HeartRateMeasurement.MEASUREMENT_UUID)
            if (status != BluetoothGatt.GATT_SUCCESS || characteristic == null) {
                post { onStatus("This device does not offer standard heart-rate data") }
                return
            }
            enableNotifications(g, characteristic)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (g !== gatt) return
            post {
                onStatus(if (status == BluetoothGatt.GATT_SUCCESS) "Receiving heart rate" else "Could not subscribe to heart rate")
            }
        }

        // Android 13+.
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (g === gatt) deliver(c, value)
        }

        // Android 12.
        @Deprecated("Replaced on Android 13 by the overload carrying the value")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            if (g === gatt && Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) deliver(c, c.value ?: return)
        }
    }

    override fun start(listener: HeartRateSource.Listener) {
        stop()
        this.listener = listener
        val scanner = adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner
        if (scanner == null) {
            listener.onStatus("Bluetooth is off or unavailable")
            return
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(HeartRateMeasurement.SERVICE_UUID)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanning = true
        scanner.startScan(filters, settings, scanCallback)
        handler.postDelayed(scanTimeout, SCAN_TIMEOUT_MILLIS)
        listener.onStatus("Searching for a heart-rate device…")
    }

    override fun stop() {
        listener = null
        stopScan()
        gatt?.let {
            gatt = null
            it.disconnect()
            it.close()
        }
    }

    private fun connect(device: BluetoothDevice) {
        listener?.onStatus("Connecting to ${device.name ?: "heart-rate device"}…")
        gatt = device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private fun enableNotifications(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
        g.setCharacteristicNotification(c, true)
        val descriptor = c.getDescriptor(HeartRateMeasurement.CLIENT_CONFIG_UUID) ?: return
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(descriptor, enable)
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = enable
            @Suppress("DEPRECATION")
            g.writeDescriptor(descriptor)
        }
    }

    private fun deliver(c: BluetoothGattCharacteristic, value: ByteArray) {
        if (c.uuid != HeartRateMeasurement.MEASUREMENT_UUID) return
        val reading = HeartRateMeasurement.parse(value) ?: return
        post { onSample(reading.bpm, reading.skinContact) }
    }

    private fun stopScan() {
        handler.removeCallbacks(scanTimeout)
        if (!scanning) return
        scanning = false
        if (adapter?.isEnabled == true) adapter.bluetoothLeScanner?.stopScan(scanCallback)
    }

    private fun post(block: HeartRateSource.Listener.() -> Unit) {
        handler.post { listener?.block() }
    }

    companion object {
        private const val SCAN_TIMEOUT_MILLIS = 15_000L
    }
}
