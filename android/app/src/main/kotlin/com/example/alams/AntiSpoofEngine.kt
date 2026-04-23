package com.example.alams

import android.content.res.AssetManager
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AntiSpoofEngine(flutterEngine: FlutterEngine, private val assetManager: AssetManager) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.alams/antispoof"
        const val TAG = "AntiSpoofEngine"

        init {
            System.loadLibrary("antispoof")
        }
    }

    private val channel: MethodChannel =
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

    private var isInitialized = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                try {
                    val ret = nativeInit(assetManager)
                    isInitialized = (ret == 0)
                    Log.i(TAG, "Native init result: $ret, initialized: $isInitialized")
                    result.success(ret == 0)
                } catch (e: Exception) {
                    Log.e(TAG, "Init failed", e)
                    result.error("INIT_FAILED", e.message, null)
                }
            }
            "detect" -> {
                if (!isInitialized) {
                    result.error("NOT_INITIALIZED", "Engine not initialized", null)
                    return
                }
                try {
                    val nv21 = call.argument<ByteArray>("nv21")!!
                    val width = call.argument<Int>("width")!!
                    val height = call.argument<Int>("height")!!
                    val orientation = call.argument<Int>("orientation")!!
                    val left = call.argument<Int>("left")!!
                    val top = call.argument<Int>("top")!!
                    val right = call.argument<Int>("right")!!
                    val bottom = call.argument<Int>("bottom")!!

                    val confidence = nativeDetect(
                        nv21, width, height, orientation,
                        left, top, right, bottom
                    )
                    result.success(confidence.toDouble())
                } catch (e: Exception) {
                    Log.e(TAG, "Detect failed", e)
                    result.error("DETECT_FAILED", e.message, null)
                }
            }
            "destroy" -> {
                nativeDestroy()
                isInitialized = false
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        nativeDestroy()
        isInitialized = false
        channel.setMethodCallHandler(null)
    }

    // Native methods
    private external fun nativeInit(assetManager: AssetManager): Int
    private external fun nativeDetect(
        nv21Data: ByteArray, width: Int, height: Int, orientation: Int,
        faceLeft: Int, faceTop: Int, faceRight: Int, faceBottom: Int
    ): Float
    private external fun nativeDestroy()
}
