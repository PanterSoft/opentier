package com.andrerinas.opentier

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.ParcelUuid
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BluetoothSearching
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.andrerinas.opentier.bluetooth.ScooterBleManager
import com.andrerinas.opentier.protocol.MyTierProtocol
import com.andrerinas.opentier.protocol.ScooterStatus
import no.nordicsemi.android.ble.ktx.stateAsFlow
import no.nordicsemi.android.support.v18.scanner.*
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private lateinit var bleManager: ScooterBleManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bleManager = ScooterBleManager(this)
        setContent {
            OpenTierTheme {
                DashboardScreen(bleManager)
            }
        }
    }
}

@Composable
fun DashboardScreen(bleManager: ScooterBleManager) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("OpenTier", Context.MODE_PRIVATE) }
    
    val receivedData by bleManager.receivedData.collectAsState()
    val connectionState by bleManager.stateAsFlow().collectAsState(initial = null)
    
    var scooterStatus by remember { mutableStateOf<ScooterStatus?>(null) }
    var password by remember { mutableStateOf(prefs.getString("password", "000000") ?: "000000") }
    var discoveredDevices = remember { mutableStateListOf<BluetoothDevice>() }
    var isScanning by remember { mutableStateOf(false) }
    
    val lastMac = prefs.getString("last_mac", null)

    val isConnectedOrConnecting = connectionState.toString().uppercase().let { 
        (it.contains("READY") || it.contains("CONNECT") || it.contains("INIT") || it.contains("SERVICE")) && !it.contains("DISCONNECT")
    }

    LaunchedEffect(receivedData) {
        receivedData?.let { raw ->
            MyTierProtocol.parseStatus(raw)?.let { newStatus -> 
                scooterStatus = if (newStatus.batteryPercentage == 0 && scooterStatus != null) {
                    newStatus.copy(batteryPercentage = scooterStatus!!.batteryPercentage)
                } else {
                    newStatus
                }
            } 
        }
    }

    LaunchedEffect(password) {
        prefs.edit().putString("password", password).apply()
    }

    LaunchedEffect(isConnectedOrConnecting) {
        if (isConnectedOrConnecting) {
            while(true) {
                bleManager.sendCommand(MyTierProtocol.getStatus(password))
                delay(5000)
                bleManager.sendCommand("AT+BK$")
                delay(25000)
            }
        }
    }

    val scanner = BluetoothLeScannerCompat.getScanner()
    val scanCallback = remember {
        object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val name = device.name ?: result.scanRecord?.deviceName
                if (lastMac != null && device.address == lastMac) {
                    isScanning = false
                    scanner.stopScan(this)
                    bleManager.connect(device).retry(3, 100).enqueue()
                    return
                }
                if (discoveredDevices.none { it.address == device.address }) {
                    val isMyTier = (name != null && (name.matches(Regex("[A-Z]{2}[0-9]{6}")) || name.contains("ES200", true))) || 
                                   (result.scanRecord?.serviceUuids?.any { it.uuid.toString().startsWith("00002c", true) } == true)
                    if (isMyTier) discoveredDevices.add(device)
                }
            }
        }
    }

    val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.ACCESS_FINE_LOCATION)
    } else {
        listOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results.values.all { it }) {
            isScanning = true
            scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
        }
    }

    LaunchedEffect(Unit) {
        val allGranted = permissions.all { 
            androidx.core.content.ContextCompat.checkSelfPermission(context, it) == android.content.pm.PackageManager.PERMISSION_GRANTED 
        }
        if (allGranted) {
            isScanning = true
            scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
        } else {
            launcher.launch(permissions.toTypedArray())
        }
    }

    if (isConnectedOrConnecting) {
        DashboardScreenContent(
            status = scooterStatus,
            connectionState = connectionState?.toString() ?: "...",
            password = password,
            onPasswordChange = { password = it },
            onActionClick = {
                val cmd = if (scooterStatus?.isLocked == true) MyTierProtocol.unlock(password) else MyTierProtocol.lock(password)
                bleManager.sendCommand(cmd)
            },
            onDisconnect = { 
                bleManager.disconnect().enqueue() 
                prefs.edit().remove("last_mac").apply() 
            }
        )
    } else {
        DeviceListScreen(
            devices = discoveredDevices,
            isScanning = isScanning,
            onDeviceClick = { device ->
                prefs.edit().putString("last_mac", device.address).apply()
                isScanning = false
                scanner.stopScan(scanCallback)
                bleManager.connect(device).retry(3, 100).enqueue()
            }
        )
    }
}

@Composable
fun DeviceListScreen(devices: List<BluetoothDevice>, isScanning: Boolean, onDeviceClick: (BluetoothDevice) -> Unit) {
    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0F1113)).padding(24.dp)) {
        Column {
            Text("Nearby Scooters", color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Text(if (isScanning) "Searching for your MyTier..." else "Scan paused", color = Color(0xFF00F2FF), fontSize = 14.sp)
            Spacer(Modifier.height(24.dp))
            if (devices.isEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Make sure your scooter is nearby and turned on.", color = Color.Gray)
                }
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(devices) { device ->
                        DeviceItem(device, onDeviceClick)
                    }
                }
            }
        }
    }
}

@Composable
fun DeviceItem(device: BluetoothDevice, onClick: (BluetoothDevice) -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable { onClick(device) },
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1E21))
    ) {
        Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Bluetooth, null, tint = Color(0xFF00F2FF))
            Spacer(Modifier.width(16.dp))
            Column {
                Text(device.name ?: "Unknown Scooter", color = Color.White, fontWeight = FontWeight.Bold)
                Text(device.address, color = Color.Gray, fontSize = 12.sp)
            }
        }
    }
}

@Composable
fun DashboardScreenContent(
    status: ScooterStatus?,
    connectionState: String,
    password: String,
    onPasswordChange: (String) -> Unit,
    onActionClick: () -> Unit,
    onDisconnect: () -> Unit
) {
    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0F1113))) {
        Column(modifier = Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("OpenTier", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                TextButton(onClick = onDisconnect) { Text("Forget Scooter", color = Color(0xFFFF4B4B)) }
            }
            Surface(color = Color(0xFF1C1E21), shape = RoundedCornerShape(16.dp), modifier = Modifier.padding(top = 8.dp)) {
                Row(modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.BluetoothSearching, null, tint = Color(0xFF00F2FF), modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(connectionState, color = Color.Gray, fontSize = 12.sp)
                }
            }
            Spacer(Modifier.height(24.dp))
            StatusCard(status)
            Spacer(Modifier.height(24.dp))
            OutlinedTextField(value = password, onValueChange = onPasswordChange, label = { Text("Scooter Password", color = Color.Gray) }, singleLine = true, modifier = Modifier.fillMaxWidth(), colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Color(0xFF00F2FF), unfocusedBorderColor = Color.DarkGray))
            Spacer(Modifier.weight(1f))
            LargeActionButton(isLocked = status?.isLocked ?: true, onClick = onActionClick)
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
fun StatusCard(status: ScooterStatus?) {
    Card(modifier = Modifier.fillMaxWidth().height(300.dp), shape = RoundedCornerShape(32.dp), colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1E21))) {
        Column(modifier = Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Box(contentAlignment = Alignment.Center) {
                CircularProgressIndicator(progress = (status?.batteryPercentage ?: 0).toFloat() / 100f, modifier = Modifier.size(200.dp), color = Color(0xFF00F2FF), strokeWidth = 12.dp, trackColor = Color(0xFF2C2F33))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("${status?.batteryPercentage ?: "--"}%", color = Color.White, fontSize = 48.sp, fontWeight = FontWeight.Black)
                    Text("Battery", color = Color.Gray, fontSize = 16.sp)
                }
            }
        }
    }
}

@Composable
fun LargeActionButton(isLocked: Boolean, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = Modifier.fillMaxWidth().height(80.dp), shape = RoundedCornerShape(24.dp), colors = ButtonDefaults.buttonColors(containerColor = if (isLocked) Color(0xFF00F2FF) else Color(0xFFFF4B4B))) {
        Icon(if (isLocked) Icons.Default.LockOpen else Icons.Default.Lock, null, tint = Color.Black)
        Spacer(Modifier.width(12.dp))
        Text(if (isLocked) "UNLOCK" else "LOCK", color = Color.Black, fontSize = 20.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun OpenTierTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xFF00F2FF), background = Color(0xFF0F1113), surface = Color(0xFF1C1E21)), content = content)
}
