package com.example.alams

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var antiSpoofEngine: AntiSpoofEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        antiSpoofEngine = AntiSpoofEngine(flutterEngine, assets)
    }

    override fun onDestroy() {
        antiSpoofEngine?.dispose()
        super.onDestroy()
    }
}
