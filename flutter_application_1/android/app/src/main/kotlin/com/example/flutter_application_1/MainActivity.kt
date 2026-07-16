package com.example.flutter_application_1

import android.content.Intent
import android.net.Uri
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Receives ride archives opened from (or shared to) the app — a `.zip` tapped
 * in a file manager, or "share to bike-assist" from a chat/mail app. The
 * incoming content:// stream is copied into the app's cache and its path is
 * handed to Flutter over a method channel, which then runs the import. This
 * lets the user import from apps that have their own back button, instead of
 * the system file picker (which has none at its root).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "bike_assist/import"
    private var channel: MethodChannel? = null

    /** Set when the app is cold-started by an intent, before Dart is ready to
     *  be called; Dart pulls it via `getInitialImport` once it's listening. */
    private var pendingImportPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel!!.setMethodCallHandler { call, result ->
            if (call.method == "getInitialImport") {
                result.success(pendingImportPath)
                pendingImportPath = null
            } else {
                result.notImplemented()
            }
        }
        // The intent that launched the process (cold start).
        pendingImportPath = extractImport(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val path = extractImport(intent) ?: return
        // App already running: deliver straight to Dart, or stash it if the
        // channel isn't wired yet.
        val ch = channel
        if (ch != null) {
            ch.invokeMethod("onImport", path)
        } else {
            pendingImportPath = path
        }
    }

    /** Copies a VIEW/SEND zip payload into cache and returns its path, or null
     *  if this intent doesn't carry one. */
    private fun extractImport(intent: Intent?): String? {
        if (intent == null) return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            else -> null
        }
        return if (uri == null) null else copyToCache(uri)
    }

    private fun copyToCache(uri: Uri): String? {
        return try {
            val input = contentResolver.openInputStream(uri) ?: return null
            val outFile = File(cacheDir, "import_${System.currentTimeMillis()}.zip")
            input.use { i -> outFile.outputStream().use { o -> i.copyTo(o) } }
            outFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "failed to read shared import $uri", e)
            null
        }
    }

    private companion object {
        const val TAG = "BikeImport"
    }
}
