package com.andrerinas.opentier.protocol

import android.util.Log

data class ScooterStatus(
    val isLocked: Boolean,
    val batteryPercentage: Int,
    val isLightOn: Boolean = false
)

object MyTierProtocol {
    
    fun lock(password: String) = "AT+BKSCT=$password,1$"
    fun unlock(password: String) = "AT+BKSCT=$password,0$"
    fun getStatus(password: String) = "AT+BKINF=$password$"

    fun parseStatus(response: String): ScooterStatus? {
        try {
            // 1. Handling von ACKs (Sofortiges Feedback)
            if (response.contains("+ACK:BKSCT,0")) return ScooterStatus(isLocked = false, batteryPercentage = 0) // Akku kommt später
            if (response.contains("+ACK:BKSCT,1")) return ScooterStatus(isLocked = true, batteryPercentage = 0)

            // 2. Handling von Status-Informationen (+BKINF)
            if (response.contains("+BKINF:")) {
                val data = response.substringAfter(":").substringBefore("$").split(",")
                
                // MyTier 1.0 hat ca. 7 Felder, 2.0 hat 23 Felder.
                // Wir suchen den Lock-Status (meist Feld 2 oder 3) und Akku (meist Feld 4 oder 5)
                return if (data.size >= 5) {
                    val lockByte = data[1] // Oft das zweite Feld
                    val battery = data[4].toIntOrNull() ?: 0
                    ScooterStatus(
                        isLocked = lockByte == "1" || lockByte == "L",
                        batteryPercentage = battery
                    )
                } else null
            }
        } catch (e: Exception) {
            Log.e("OpenTier", "Parse Error: ${e.message}")
        }
        return null
    }
}
