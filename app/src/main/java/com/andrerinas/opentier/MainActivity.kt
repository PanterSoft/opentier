package com.andrerinas.opentier

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.content.edit
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.runtime.saveable.rememberSaveable
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
    DashboardScreen(prefs, bleManager)
}

@Composable
fun DashboardScreen(prefs: SharedPreferences, bleManager: ScooterBleManager) {
    val context = LocalContext.current
    
    val receivedData by bleManager.receivedData.collectAsState()
    val connectionState by bleManager.stateAsFlow().collectAsState(initial = null)
    
    val lastMac = prefs.getString("last_mac", null)
    var currentMac by rememberSaveable { mutableStateOf(lastMac) }
    
    var scooterStatus by remember { mutableStateOf<ScooterStatus?>(null) }
    var discoveredDevices = remember { mutableStateListOf<BluetoothDevice>() }
    var isScanning by remember { mutableStateOf(false) }
    var isAutoConnectEnabled by rememberSaveable { mutableStateOf(true) }
    
    // Passwort und Name pro MAC laden
    var password by remember(currentMac) { 
        mutableStateOf(prefs.getString("pass_$currentMac", "") ?: "") 
    }
    var scooterCustomName by remember(currentMac) {
        mutableStateOf(prefs.getString("name_$currentMac", "My Scooter") ?: "My Scooter")
    }

    LaunchedEffect(scooterCustomName) {
        if (currentMac != null) {
            prefs.edit { putString("name_$currentMac", scooterCustomName) }
        }
    }

    LaunchedEffect(password) {
        if (currentMac != null && password.isNotEmpty()) {
            prefs.edit { putString("pass_$currentMac", password) }
        }
    }

    val isConnectedOrConnecting = connectionState.toString().uppercase().let { 
        (it.contains("READY") || it.contains("CONNECT") || it.contains("INIT") || it.contains("SERVICE")) && !it.contains("DISCONNECT")
    }

    LaunchedEffect(receivedData) {
        receivedData?.let { raw ->
            Log.d("OpenTier", "Parsing raw data: $raw")
            MyTierProtocol.parseStatus(raw)?.let { newStatus -> 
                scooterStatus = if (newStatus.batteryPercentage == 0 && scooterStatus != null) {
                    newStatus.copy(batteryPercentage = scooterStatus!!.batteryPercentage)
                } else {
                    newStatus
                }
            } 
        }
    }

    val scanner = BluetoothLeScannerCompat.getScanner()
    val scanCallback = remember {
        object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val name = device.name ?: result.scanRecord?.deviceName
                
                // Auto-Connect nur wenn erlaubt
                if (isAutoConnectEnabled && lastMac != null && device.address == lastMac) {
                    isScanning = false
                    scanner.stopScan(this)
                    currentMac = device.address
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
        }
    }

    LaunchedEffect(currentMac) {
        if (currentMac != null && !isConnectedOrConnecting) {
            try {
                val adapter = BluetoothAdapter.getDefaultAdapter()
                if (adapter != null) {
                    val device = adapter.getRemoteDevice(currentMac)
                    bleManager.connect(device).retry(3, 100).enqueue()
                }
            } catch (e: Exception) {
                Log.e("OpenTier", "Failed to auto-reconnect: ${e.message}")
            }
        }
    }

    LaunchedEffect(isConnectedOrConnecting, password) {
        if (isConnectedOrConnecting) {
            while(true) {
                bleManager.sendCommand(MyTierProtocol.getStatus(password))
                delay(10000)
            }
        } else {
            // Wenn nicht verbunden, Scan-Flag setzen
            isScanning = true
        }
    }

    LaunchedEffect(isScanning) {
        if (isScanning) {
            val allGranted = permissions.all { 
                androidx.core.content.ContextCompat.checkSelfPermission(context, it) == android.content.pm.PackageManager.PERMISSION_GRANTED 
            }
            if (allGranted) {
                discoveredDevices.clear()
                // Sicherheitshalber erst stoppen, falls noch ein alter Scan läuft
                scanner.stopScan(scanCallback)
                scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
            } else {
                launcher.launch(permissions.toTypedArray())
            }
        } else {
            scanner.stopScan(scanCallback)
        }
    }

    if (isConnectedOrConnecting) {
        DashboardScreenContent(
            status = scooterStatus,
            connectionState = connectionState.toString(),
            password = password,
            scooterName = scooterCustomName,
            onPasswordChange = { password = it },
            onNameChange = { scooterCustomName = it },
            onActionClick = {
                if (scooterStatus?.isLocked == true) {
                    bleManager.sendCommand(MyTierProtocol.unlock(password))
                } else {
                    bleManager.sendCommand(MyTierProtocol.lock(password))
                }
            },
            onDisconnect = { 
                bleManager.disconnect().enqueue() 
                isAutoConnectEnabled = false // Auto-Connect stoppen beim manuellen Trennen
                currentMac = null
            },
            onForget = {
                bleManager.disconnect().enqueue()
                prefs.edit { 
                    remove("last_mac")
                    remove("pass_$currentMac")
                    remove("name_$currentMac")
                }
                currentMac = null
            }
        )
    } else {
        DeviceListScreen(
            devices = discoveredDevices,
            isScanning = isScanning,
            prefs = prefs,
            onDeviceClick = { device ->
                currentMac = device.address
                isAutoConnectEnabled = true // Wieder aktivieren bei manuellem Klick
                prefs.edit { putString("last_mac", device.address) }
                bleManager.connect(device).retry(3, 100).enqueue()
            }
        )
    }
}

@Composable
fun DeviceListScreen(devices: List<BluetoothDevice>, isScanning: Boolean, prefs: SharedPreferences, onDeviceClick: (BluetoothDevice) -> Unit) {
    val savedMacs = prefs.all.keys.filter { it.startsWith("pass_") }.map { it.removePrefix("pass_") }
    val savedDevices = devices.filter { it.address in savedMacs }
    val newDevices = devices.filter { it.address !in savedMacs }

    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0F1113)).padding(24.dp)) {
        Column {
            Text("OpenTier Garage", color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Text(if (isScanning) "Searching for scooters..." else "Scan paused", color = Color(0xFF00F2FF), fontSize = 14.sp)
            Spacer(Modifier.height(24.dp))

            LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (savedDevices.isNotEmpty()) {
                    item { Text("YOUR SAVED SCOOTERS", color = Color.Gray, fontSize = 12.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 8.dp)) }
                    items(savedDevices) { device ->
                        val customName = prefs.getString("name_${device.address}", device.name ?: "Unknown") ?: "Unknown"
                        DeviceItem(device, customName, onDeviceClick)
                    }
                    item { Spacer(Modifier.height(24.dp)) }
                }

                if (newDevices.isNotEmpty()) {
                    item { Text("DISCOVERED NEARBY", color = Color.Gray, fontSize = 12.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 8.dp)) }
                    items(newDevices) { device ->
                        DeviceItem(device, device.name ?: "New Scooter", onDeviceClick)
                    }
                }
            }
        }
    }
}

@Composable
fun DeviceItem(device: BluetoothDevice, displayName: String, onClick: (BluetoothDevice) -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable { onClick(device) },
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF1C1E21))
    ) {
        Row(modifier = Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Bluetooth, null, tint = Color(0xFF00F2FF))
            Spacer(Modifier.width(16.dp))
            Column {
                Text(displayName, color = Color.White, fontWeight = FontWeight.Bold)
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
    scooterName: String,
    onPasswordChange: (String) -> Unit,
    onNameChange: (String) -> Unit,
    onActionClick: () -> Unit,
    onDisconnect: () -> Unit,
    onForget: () -> Unit
) {
    var passwordVisible by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0F1113))) {
        Column(modifier = Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(scooterName, color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Row {
                    TextButton(onClick = onDisconnect) { Text("Switch", color = Color(0xFF00F2FF)) }
                    TextButton(onClick = onForget) { Text("Forget", color = Color(0xFFFF4B4B)) }
                }
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
            OutlinedTextField(value = scooterName, onValueChange = onNameChange, label = { Text("Scooter Name", color = Color.Gray) }, singleLine = true, modifier = Modifier.fillMaxWidth(), colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Color(0xFF00F2FF), unfocusedBorderColor = Color.DarkGray))
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = password, 
                onValueChange = onPasswordChange, 
                label = { Text("Scooter Password", color = Color.Gray) }, 
                singleLine = true, 
                modifier = Modifier.fillMaxWidth(), 
                visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { passwordVisible = !passwordVisible }) {
                        Icon(if (passwordVisible) Icons.Default.LockOpen else Icons.Default.Lock, null, tint = Color.Gray)
                    }
                },
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, focusedBorderColor = Color(0xFF00F2FF), unfocusedBorderColor = Color.DarkGray)
            )
            Spacer(Modifier.height(24.dp))
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
                    if (status != null) {
                        Text("${String.format("%.1f", status.estimatedRange)} km", color = Color(0xFF00F2FF), fontSize = 14.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                    }
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
