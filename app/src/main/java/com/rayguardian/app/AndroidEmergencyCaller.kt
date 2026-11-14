package com.rayguardian.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.ContextCompat

object AndroidEmergencyCaller {
    @SuppressLint("MissingPermission")
    fun placeCall(context: Context, rawNumber: String?): EmergencyDialer.CallOutcome {
        return when (val check = EmergencyDialer.validateNumber(rawNumber)) {
            EmergencyDialer.Validation.Empty -> EmergencyDialer.CallOutcome.NoNumberConfigured
            EmergencyDialer.Validation.BlockedEmergencyShortcode -> EmergencyDialer.CallOutcome.BlockedShortcode
            EmergencyDialer.Validation.InvalidFormat -> EmergencyDialer.CallOutcome.InvalidNumber
            is EmergencyDialer.Validation.Valid -> {
                val uri = Uri.parse("tel:${check.normalizedNumber}")
                val canCallDirectly = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.CALL_PHONE,
                ) == PackageManager.PERMISSION_GRANTED
                try {
                    if (canCallDirectly) {
                        context.startActivity(Intent(Intent.ACTION_CALL, uri))
                        EmergencyDialer.CallOutcome.PlacedDirectCall(check.normalizedNumber)
                    } else {
                        context.startActivity(Intent(Intent.ACTION_DIAL, uri))
                        EmergencyDialer.CallOutcome.OpenedDialer(check.normalizedNumber)
                    }
                } catch (_: Exception) {
                    try {
                        context.startActivity(Intent(Intent.ACTION_DIAL, uri))
                        EmergencyDialer.CallOutcome.OpenedDialer(check.normalizedNumber)
                    } catch (dialError: Exception) {
                        EmergencyDialer.CallOutcome.Failed(dialError.message ?: "No dialer app available")
                    }
                }
            }
        }
    }
}

class ServicePhoneStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("ray_guardian_service_numbers", Context.MODE_PRIVATE)

    var autoDialEnabled: Boolean
        get() = prefs.getBoolean("auto_dial_enabled", true)
        set(value) = prefs.edit().putBoolean("auto_dial_enabled", value).apply()

    fun getNumber(service: HelpService): String =
        prefs.getString("phone_${service.wireName}", "").orEmpty()

    fun setNumber(service: HelpService, value: String) {
        prefs.edit().putString("phone_${service.wireName}", value.trim()).apply()
    }
}
