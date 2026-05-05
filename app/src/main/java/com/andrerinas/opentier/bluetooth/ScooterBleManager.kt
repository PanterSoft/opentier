package com.andrerinas.opentier.bluetooth

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.content.Context
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import no.nordicsemi.android.ble.BleManager
import java.util.*

class ScooterBleManager(context: Context) : BleManager(context) {

    private var writeCharacteristic: BluetoothGattCharacteristic? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null

    private val _receivedData = MutableStateFlow<String?>(null)
    val receivedData = _receivedData.asStateFlow()

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("00002C00-0000-1000-8000-00805f9b34fb")
        val CHAR_WRITE: UUID = UUID.fromString("00002C01-0000-1000-8000-00805f9b34fb")
        val CHAR_NOTIFY: UUID = UUID.fromString("00002C10-0000-1000-8000-00805f9b34fb")
    }

    override fun getGattCallback(): BleManagerGattCallback = ScooterGattCallback()

    private inner class ScooterGattCallback : BleManagerGattCallback() {
        override fun isRequiredServiceSupported(gatt: BluetoothGatt): Boolean {
            val service = gatt.getService(SERVICE_UUID) ?: gatt.services.firstOrNull { 
                it.uuid.toString().startsWith("00002c", ignoreCase = true)
            }

            writeCharacteristic = service?.getCharacteristic(CHAR_WRITE)
            notifyCharacteristic = service?.getCharacteristic(CHAR_NOTIFY)

            return writeCharacteristic != null && notifyCharacteristic != null
        }

        override fun initialize() {
            setNotificationCallback(notifyCharacteristic)
                .with { device, data ->
                    val text = data.value?.let { String(it) }
                    Log.d("OpenTier", "RECV: $text")
                    _receivedData.value = text
                }
            enableNotifications(notifyCharacteristic).enqueue()
        }

        override fun onServicesInvalidated() {
            writeCharacteristic = null
            notifyCharacteristic = null
        }
    }

    fun sendCommand(command: String) {
        if (writeCharacteristic == null) {
            Log.e("OpenTier", "SEND FAILED: Write Characteristic NULL")
            return
        }
        // Viele OKAI Roller brauchen \r\n am Ende
        val finalCommand = if (command.endsWith("\r\n")) command else "$command\r\n"
        val bytes = finalCommand.toByteArray()

        Log.d("OpenTier", "SENDING: ${finalCommand.trim()}")

        bytes.toList().chunked(20).forEach { chunk ->
            writeCharacteristic(writeCharacteristic, chunk.toByteArray(), BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                .enqueue()
        }
    }
}
