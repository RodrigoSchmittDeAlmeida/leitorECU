package com.leitorecu.leitorecu_mobile

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.leitorecu.mobile/background"
        private const val SECURE_STORAGE_CHANNEL = "com.leitorecu.mobile/secure_storage"
        private const val SECURE_PREFS_NAME = "leitorecu_secure_prefs"
        private const val FALLBACK_KEY_PREFS = "leitorecu_secure_k_fallback"
        private const val MASTER_KEY_ALIAS = "leitorecu_ai_master_key"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val AES_GCM_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_IV_LENGTH = 12
        private const val GCM_TAG_LENGTH_BITS = 128
    }

    private val secureLock = Any()

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "write" -> {
                        val key = call.argument<String>("key")
                        val value = call.argument<String>("value")
                        if (key.isNullOrBlank() || value == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(writeSecureValue(key, value))
                    }

                    "read" -> {
                        val key = call.argument<String>("key")
                        if (key.isNullOrBlank()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        result.success(readSecureValue(key))
                    }

                    "delete" -> {
                        val key = call.argument<String>("key")
                        if (key.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(deleteSecureValue(key))
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun getOrCreateMasterKey(): SecretKey {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val existing = keyStore.getKey(MASTER_KEY_ALIAS, null) as? SecretKey
            if (existing != null) return existing

            val keyGenerator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                ANDROID_KEYSTORE
            )
            val spec = KeyGenParameterSpec.Builder(
                MASTER_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
            keyGenerator.init(spec)
            return keyGenerator.generateKey()
        }

        val prefs = getSharedPreferences(FALLBACK_KEY_PREFS, Context.MODE_PRIVATE)
        val existingB64 = prefs.getString(MASTER_KEY_ALIAS, null)
        if (!existingB64.isNullOrEmpty()) {
            val raw = Base64.decode(existingB64, Base64.NO_WRAP)
            return SecretKeySpec(raw, "AES")
        }
        val keyBytes = ByteArray(32)
        SecureRandom().nextBytes(keyBytes)
        prefs.edit()
            .putString(MASTER_KEY_ALIAS, Base64.encodeToString(keyBytes, Base64.NO_WRAP))
            .apply()
        return SecretKeySpec(keyBytes, "AES")
    }

    private fun writeSecureValue(key: String, value: String): Boolean {
        return synchronized(secureLock) {
            try {
                val secretKey = getOrCreateMasterKey()
                val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    cipher.init(Cipher.ENCRYPT_MODE, secretKey)
                } else {
                    val iv = ByteArray(GCM_IV_LENGTH)
                    SecureRandom().nextBytes(iv)
                    cipher.init(
                        Cipher.ENCRYPT_MODE,
                        secretKey,
                        GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
                    )
                }
                val iv = cipher.iv
                if (iv == null || iv.size != GCM_IV_LENGTH) {
                    return@synchronized false
                }
                val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                val combined = ByteArray(iv.size + ciphertext.size)
                System.arraycopy(iv, 0, combined, 0, iv.size)
                System.arraycopy(ciphertext, 0, combined, iv.size, ciphertext.size)
                val encoded = Base64.encodeToString(combined, Base64.NO_WRAP)
                getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString(key, encoded)
                    .apply()
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun readSecureValue(key: String): String? {
        return synchronized(secureLock) {
            try {
                val encoded = getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                    .getString(key, null)
                if (encoded.isNullOrEmpty()) return@synchronized null
                val combined = Base64.decode(encoded, Base64.NO_WRAP)
                if (combined.size <= GCM_IV_LENGTH) return@synchronized null
                val iv = combined.copyOfRange(0, GCM_IV_LENGTH)
                val ciphertext = combined.copyOfRange(GCM_IV_LENGTH, combined.size)
                val secretKey = getOrCreateMasterKey()
                val cipher = Cipher.getInstance(AES_GCM_TRANSFORMATION)
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    secretKey,
                    GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
                )
                val plainBytes = cipher.doFinal(ciphertext)
                String(plainBytes, Charsets.UTF_8)
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun deleteSecureValue(key: String): Boolean {
        return synchronized(secureLock) {
            try {
                getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .remove(key)
                    .apply()
                true
            } catch (_: Exception) {
                false
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
