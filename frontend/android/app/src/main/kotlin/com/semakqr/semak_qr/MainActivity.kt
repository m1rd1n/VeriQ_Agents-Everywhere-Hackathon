package com.semakqr.semak_qr

import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/**
 * Watches MediaStore for freshly-created screenshot entries. It sends no file
 * paths to Dart and never reads/copies image data, preserving the app's
 * in-memory-only privacy guarantee. Android does not expose a screenshot
 * broadcast, so MediaStore observation is the platform-native equivalent.
 */
class MainActivity : FlutterActivity() {
    private var sink: EventChannel.EventSink? = null
    private var observer: ContentObserver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.semakqr/screenshot_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                        override fun onChange(selfChange: Boolean, uri: Uri?) {
                            val path = uri?.toString()?.lowercase() ?: return
                            if (path.contains("screenshot")) sink?.success("screenshot_detected")
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
