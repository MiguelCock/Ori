package com.example.campus_guia

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.content.Context
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // Channel de permisos (sin cambios)
    private val PERMISSIONS_CHANNEL = "campus_guia/permissions"

    // HU-17: Channel de vibración
    private val HAPTIC_CHANNEL = "campus_guia/haptic"

    private val permissionMap = mapOf(
        "location" to Manifest.permission.ACCESS_FINE_LOCATION,
        "microphone" to Manifest.permission.RECORD_AUDIO
    )

    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermission: String? = null
    private val REQUEST_CODE = 100

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Channel de permisos (sin cambios respecto al original) ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PERMISSIONS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    val permissionKey = call.argument<String>("permission")
                        ?: return@setMethodCallHandler result.error(
                            "INVALID_ARG", "Falta el argumento 'permission'", null
                        )
                    val androidPermission = permissionMap[permissionKey]
                        ?: return@setMethodCallHandler result.error(
                            "UNKNOWN_PERMISSION", "Permiso desconocido: $permissionKey", null
                        )
                    if (ContextCompat.checkSelfPermission(this, androidPermission)
                        == PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success("granted")
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPermission = permissionKey
                    ActivityCompat.requestPermissions(
                        this, arrayOf(androidPermission), REQUEST_CODE
                    )
                }
                "checkPermission" -> {
                    val permissionKey = call.argument<String>("permission")
                        ?: return@setMethodCallHandler result.error(
                            "INVALID_ARG", "Falta el argumento 'permission'", null
                        )
                    val androidPermission = permissionMap[permissionKey]
                        ?: return@setMethodCallHandler result.error(
                            "UNKNOWN_PERMISSION", "Permiso desconocido: $permissionKey", null
                        )
                    val status = if (
                        ContextCompat.checkSelfPermission(this, androidPermission)
                        == PackageManager.PERMISSION_GRANTED
                    ) "granted" else "denied"
                    result.success(status)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HAPTIC_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "vibrate" -> {
                    val pattern = call.argument<List<Int>>("pattern")
                    if (pattern == null || pattern.isEmpty()) {
                        result.error("INVALID_ARG", "Falta el patrón de vibración", null)
                        return@setMethodCallHandler
                    }
                    // Convertir List<Int> a LongArray para Android
                    val timings = pattern.map { it.toLong() }.toLongArray()
                    val success = vibrate(timings)
                    result.success(success)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── Vibración compatible con Android 8+ y versiones anteriores ──
    private fun vibrate(pattern: LongArray): Boolean {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+: usa VibratorManager
                val vibratorManager =
                    getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                val vibrator = vibratorManager.defaultVibrator
                if (!vibrator.hasVibrator()) return false
                // -1 como repeatIndex = no repetir
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
                return true
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Android 8-11: usa Vibrator directamente
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                @Suppress("DEPRECATION")
                if (!vibrator.hasVibrator()) return false
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
                return true
            } else {
                // Android < 8: API legacy
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                @Suppress("DEPRECATION")
                if (!vibrator.hasVibrator()) return false
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, -1)
                return true
            }
        } catch (e: Exception) {
            // Si el dispositivo no tiene vibrador o falla el canal
            return false
        }
    }

    // ── Callback de permisos (sin cambios) ──
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return

        val result = pendingResult ?: return
        val permissionKey = pendingPermission ?: return
        pendingResult = null
        pendingPermission = null

        if (grantResults.isEmpty()) {
            result.success("denied")
            return
        }

        when (grantResults[0]) {
            PackageManager.PERMISSION_GRANTED -> result.success("granted")
            else -> {
                val androidPermission = permissionMap[permissionKey] ?: ""
                val isPermanent = !ActivityCompat
                    .shouldShowRequestPermissionRationale(this, androidPermission)
                result.success(if (isPermanent) "permanently_denied" else "denied")
            }
        }
    }
}