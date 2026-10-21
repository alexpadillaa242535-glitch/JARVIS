package com.jarvis.jarvis_mobile

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.speech.tts.TextToSpeech
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Captura TODAS las notificaciones (de cualquier app) y las manda al backend,
 * que decide con IA cuáles son relevantes. Si el backend responde con "speak"
 * (app cerrada), las dice en voz alta con el TTS de Android.
 */
class JarvisNotificationService : NotificationListenerService() {
    private val executor = Executors.newSingleThreadExecutor()
    private val recent = LinkedHashMap<String, Long>()
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    override fun onCreate() {
        super.onCreate()
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = Locale("es", "AR")
                ttsReady = true
            }
        }
    }

    override fun onDestroy() {
        tts?.shutdown()
        executor.shutdown()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            if (sbn.packageName == packageName) return
            val n = sbn.notification ?: return
            // Resúmenes de grupo y notificaciones persistentes (música, llamadas en curso) no aportan
            if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
            if ((n.flags and Notification.FLAG_ONGOING_EVENT) != 0) return

            val extras = n.extras
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
            val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
            if (title.isBlank() && text.isBlank()) return

            // Evita duplicados idénticos en 15 segundos
            val dedupe = "${sbn.packageName}|$title|$text"
            val now = System.currentTimeMillis()
            synchronized(recent) {
                val last = recent[dedupe]
                if (last != null && now - last < 15000) return
                recent[dedupe] = now
                if (recent.size > 100) recent.remove(recent.keys.first())
            }

            val prefs = getSharedPreferences(JarvisPrefs.NAME, Context.MODE_PRIVATE)
            val url = (prefs.getString("backend_url", "") ?: "").trimEnd('/')
            val token = prefs.getString("token", "") ?: ""
            if (url.isBlank() || token.isBlank()) return

            val appName = try {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
            } catch (e: Exception) {
                sbn.packageName
            }

            val body = JSONObject()
                .put("package", sbn.packageName)
                .put("app", appName)
                .put("title", title.take(200))
                .put("text", text.take(600))
                .put("ts", sbn.postTime)
                .put("key", sbn.key)
                .toString()

            executor.execute { post("$url/notifications", token, body) }
        } catch (_: Exception) {
        }
    }

    private fun post(url: String, token: String, json: String) {
        try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.connectTimeout = 8000
            c.readTimeout = 20000
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            c.setRequestProperty("X-Jarvis-Token", token)
            c.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
            if (c.responseCode == 200) {
                val resp = c.inputStream.bufferedReader().use { it.readText() }
                val speak = JSONObject(resp).optString("speak", "")
                if (speak.isNotBlank() && ttsReady) {
                    tts?.speak(speak, TextToSpeech.QUEUE_ADD, null, "jarvis-notif")
                }
            }
            c.disconnect()
        } catch (_: Exception) {
        }
    }
}
