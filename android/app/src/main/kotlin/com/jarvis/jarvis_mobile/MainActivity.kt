package com.jarvis.jarvis_mobile

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object JarvisPrefs {
    const val NAME = "jarvis_prefs"
}

class MainActivity : FlutterActivity() {
    private val channelName = "jarvis/native"

    private val prefs get() = getSharedPreferences(JarvisPrefs.NAME, MODE_PRIVATE)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setConfig" -> {
                    prefs.edit()
                        .putString("backend_url", call.argument<String>("url") ?: "")
                        .putString("token", call.argument<String>("token") ?: "")
                        .apply()
                    result.success(true)
                }
                "getConfig" -> result.success(
                    mapOf(
                        "url" to (prefs.getString("backend_url", "") ?: ""),
                        "token" to (prefs.getString("token", "") ?: "")
                    )
                )
                "status" -> result.success(
                    mapOf(
                        "notif" to isNotifEnabled(),
                        "access" to (JarvisAccessibilityService.instance != null)
                    )
                )
                "openNotifSettings" -> {
                    startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "openAccessSettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "openAppDetails" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                }
                "minimize" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "globalAction" -> {
                    val svc = JarvisAccessibilityService.instance
                    result.success(svc?.globalAction(call.argument<String>("name") ?: "") ?: false)
                }
                "readScreen" -> {
                    val svc = JarvisAccessibilityService.instance
                    result.success(svc?.readScreen() ?: "")
                }
                "clickText" -> {
                    val svc = JarvisAccessibilityService.instance
                    result.success(svc?.clickByText(call.argument<String>("text") ?: "") ?: false)
                }
                "openApp" -> result.success(openApp(call.argument<String>("target") ?: ""))
                else -> result.notImplemented()
            }
        }
    }

    private fun isNotifEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
        return flat.contains(packageName)
    }

    /** Abre una app por nombre de paquete o por el nombre que se ve en el lanzador (ej: "WhatsApp"). */
    private fun openApp(target: String): Boolean {
        if (target.isBlank()) return false
        val pm = packageManager
        var pkg: String? = null
        if (target.contains(".") && pm.getLaunchIntentForPackage(target) != null) {
            pkg = target
        } else {
            val t = target.trim().lowercase()
            val apps = pm.getInstalledApplications(0).filter { pm.getLaunchIntentForPackage(it.packageName) != null }
            val exact = apps.firstOrNull { pm.getApplicationLabel(it).toString().lowercase() == t }
            val partial = apps.firstOrNull { pm.getApplicationLabel(it).toString().lowercase().contains(t) }
            pkg = (exact ?: partial)?.packageName
        }
        val intent = pkg?.let { pm.getLaunchIntentForPackage(it) } ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return true
    }
}
