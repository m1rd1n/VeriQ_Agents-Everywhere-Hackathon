package com.semakqr.semak_qr

import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Watches MediaStore for freshly-created screenshot entries. Screenshot bytes
 * are supplied to Dart only on demand and stay in request memory; this app
 * never copies or persists them. Android has no screenshot broadcast, so
 * MediaStore observation is the platform-native equivalent.
 */
class MainActivity : FlutterActivity() {
    private var sink: EventChannel.EventSink? = null
    private var observer: ContentObserver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.semakqr/screenshot_reader")
            .setMethodCallHandler { call, result ->
                if (call.method != "readScreenshot") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val rawUri = call.argument<String>("uri")
                if (rawUri == null) {
                    result.error("missing_uri", "No screenshot URI supplied", null)
                    return@setMethodCallHandler
                }
                try {
                    val bytes = contentResolver.openInputStream(Uri.parse(rawUri))?.use { it.readBytes() }
                    if (bytes == null) result.error("unreadable", "Screenshot could not be read", null)
                    else result.success(bytes)
                } catch (_: Exception) {
                    result.error("unreadable", "Screenshot could not be read", null)
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.semakqr/screenshot_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                        override fun onChange(selfChange: Boolean, uri: Uri?) {
                            val itemUri = uri ?: return
                            val projection = arrayOf(
                                MediaStore.Images.Media.DISPLAY_NAME,
                                MediaStore.Images.Media.RELATIVE_PATH
                            )
                            try {
                                contentResolver.query(itemUri, projection, null, null, null)?.use { cursor ->
                                    if (!cursor.moveToFirst()) return@use
                                    val name = cursor.getString(0).orEmpty().lowercase()
                                    val path = cursor.getString(1).orEmpty().lowercase()
                                    if (name.contains("screenshot") || path.contains("screenshot")) {
                                        sink?.success(itemUri.toString())
                                    }
                                }
                            } catch (_: Exception) {
                                // Access can be denied by the originating app or Android version.
                            }
                        }
                    }
                    contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer!!)
                }
                override fun onCancel(arguments: Any?) {
                    observer?.let { contentResolver.unregisterContentObserver(it) }
                    observer = null; sink = null
                }
            })
    }
    override fun onDestroy() {
        observer?.let { contentResolver.unregisterContentObserver(it) }
        super.onDestroy()
    }
}
