# Nordic BLE Library rules
-keep class no.nordicsemi.android.ble.** { *; }
-keep class no.nordicsemi.android.support.v18.scanner.** { *; }

# Compose rules (usually handled automatically, but for safety)
-keep class androidx.compose.** { *; }
-dontwarn androidx.compose.**
