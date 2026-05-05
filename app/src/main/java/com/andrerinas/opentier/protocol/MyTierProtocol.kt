package com.andrerinas.opentier.protocol

import android.util.Log

data class ScooterStatus(
    val isLocked: Boolean,
    val batteryPercentage: Int,
    val mileage: Float = 0f,
    val estimatedRange: Float = 0f
)

object MyTierProtocol {
    
    fun lock(password: String) = "AT+BKSCT=$password,1$\r\n"
    fun unlock(password: String) = "AT+BKSCT=$password,0$\r\n"
    fun getStatus(password: String) = "AT+BKINF=$password,0$\r\n"

    fun parseStatus(response: String): ScooterStatus? {
        try {
            if (response.contains("+ACK:BKSCT,0")) return ScooterStatus(isLocked = false, batteryPercentage = 0)
            if (response.contains("+ACK:BKSCT,1")) return ScooterStatus(isLocked = true, batteryPercentage = 0)

            if (response.contains(",") && response.contains("$")) {
                val clean = response.substringAfter(":").replace("$", "").replace("\r\n", "")
                val data = clean.split(",")
                
                if (data.size >= 5) {
                    val mileage = data[1].trim().toFloatOrNull() ?: 0f
                    val battery = data[3].trim().toIntOrNull() ?: 0
                    val lockStatus = data[4].trim()
                    
                    val rangeMultiplier = if (battery < 50) 0.3f else 0.35f
                    val estimatedRange = battery * rangeMultiplier
                    
                    return ScooterStatus(
                        isLocked = lockStatus == "0",
                        batteryPercentage = battery,
                        mileage = mileage,
                        estimatedRange = estimatedRange
                    )
                } else if (data.size >= 4) {
                    val lockStatus = data[0].trim()
                    val mileage = data[1].trim().toFloatOrNull() ?: 0f
                    val battery = data[3].trim().toIntOrNull() ?: 0
                    
                    val rangeMultiplier = if (battery < 50) 0.3f else 0.35f
                    val estimatedRange = battery * rangeMultiplier
                    
                    return ScooterStatus(
                        isLocked = lockStatus == "1" || lockStatus == "L",
                        batteryPercentage = battery,
                        mileage = mileage,
                        estimatedRange = estimatedRange
                    )
                }
            }
        } catch (e: Exception) {
            Log.e("OpenTier", "Parse Error: ${e.message}")
        }
        return null
    }
}
