package com.leitorecu.leitorecu_mobile

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.leitorecu.mobile/background"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val title = call.argument<String>("title") ?: "leitorECU · Telemetria Ativa"
                        val text = call.argument<String>("text")
                            ?: "Aquisição OBD-II ativa em segundo plano"
                        val intent = Intent(this, TelemetryForegroundService::class.java).apply {
                            action = TelemetryForegroundService.ACTION_START
                            putExtra(TelemetryForegroundService.EXTRA_TITLE, title)
                            putExtra(TelemetryForegroundService.EXTRA_TEXT, text)
                        }
                        try {
                            ContextCompat.startForegroundService(this, intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }

                    "updateService" -> {
                        if (!TelemetryForegroundService.isServiceRunning) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val title = call.argument<String>("title") ?: "leitorECU · Telemetria Ativa"
                        val text = call.argument<String>("text")
                            ?: "Aquisição OBD-II ativa em segundo plano"
                        val intent = Intent(this, TelemetryForegroundService::class.java).apply {
                            action = TelemetryForegroundService.ACTION_UPDATE
                            putExtra(TelemetryForegroundService.EXTRA_TITLE, title)
                            putExtra(TelemetryForegroundService.EXTRA_TEXT, text)
                        }
                        try {
                            startService(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }

                    "stopService" -> {
                        val intent = Intent(this, TelemetryForegroundService::class.java).apply {
                            action = TelemetryForegroundService.ACTION_STOP
                        }
                        try {
                            stopService(intent)
                        } catch (_: Exception) {
                        }
                        result.success(true)
                    }

                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isBatteryOptimizationIgnored())
                    }

                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(openBatteryOptimizationDialog())
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun isBatteryOptimizationIgnored(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    @SuppressLint("BatteryLife")
    private fun openBatteryOptimizationDialog(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isBatteryOptimizationIgnored()) return true
        return try {
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: Exception) {
                false
            }
        }
    }
}
