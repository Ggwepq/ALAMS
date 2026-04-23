import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;

/// Commands sent to the [SpoofWorker].
enum SpoofCommand { detect, stop }

/// Data structure for passing camera frame data to the isolate.
class SpoofFrameData {
  final List<Uint8List> planes;
  final int width;
  final int height;
  final List<int> bytesPerPixel;
  final List<int> bytesPerRow;
  final String? debugPath;
  final List<double>? cropRect; // [left, top, right, bottom] in frame space

  SpoofFrameData({
    required this.planes,
    required this.width,
    required this.height,
    required this.bytesPerPixel,
    required this.bytesPerRow,
    this.debugPath,
    this.cropRect,
  });
}

/// The result returned by the worker.
class SpoofWorkerResult {
  final bool isReal;
  final double confidence;
  final List<double>? diagnostics;
  
  SpoofWorkerResult({required this.isReal, required this.confidence, this.diagnostics});
}

/// Background worker that runs TFLite anti-spoofing in a persistent Isolate.
class SpoofWorker {
  final SendPort _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  
  StreamSubscription? _subscription;
  Completer<SpoofWorkerResult>? _pendingTask;

  SpoofWorker(this._sendPort) {
    _subscription = _receivePort.listen(_handleMessage);
  }

  static Future<SpoofWorker> spawn(Uint8List modelData) async {
    final handshakePort = ReceivePort();
    final RootIsolateToken? token = RootIsolateToken.instance;
    
    debugPrint('[SpoofWorker] Spawning background isolate...');
    
    await Isolate.spawn(_isolateMain, {
      'handshakePort': handshakePort.sendPort,
      'token': token,
      'modelData': modelData,
    });
    
    final isolateSendPort = await handshakePort.first as SendPort;
    final worker = SpoofWorker(isolateSendPort);
    isolateSendPort.send(worker._receivePort.sendPort);
    
    return worker;
  }

  void _handleMessage(dynamic message) {
    if (message == 'ready') {
      debugPrint('[SpoofWorker] AI Model is FULLY LOADED and READY in background.');
      _ready.complete();
    } else if (message is SpoofWorkerResult) {
      _pendingTask?.complete(message);
      _pendingTask = null;
    }
  }

  bool get isBusy => _pendingTask != null;

  Future<SpoofWorkerResult> detect(SpoofFrameData data) async {
    if (!_ready.isCompleted) {
      return SpoofWorkerResult(isReal: true, confidence: 0.0);
    }
    
    if (_pendingTask != null) {
      return SpoofWorkerResult(isReal: true, confidence: 0.0);
    }
    
    _pendingTask = Completer<SpoofWorkerResult>();
    _sendPort.send({'cmd': SpoofCommand.detect, 'data': data});
    return _pendingTask!.future;
  }

  void dispose() {
    _sendPort.send({'cmd': SpoofCommand.stop});
    _subscription?.cancel();
    _receivePort.close();
  }

  // --- ISOLATE ENTRY POINT ---

  static void _isolateMain(Map<String, dynamic> params) async {
    final SendPort handshakePort = params['handshakePort'];
    final RootIsolateToken? token = params['token'];
    final Uint8List modelData = params['modelData'];
    
    if (token != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    }

    final isolateReceivePort = ReceivePort();
    handshakePort.send(isolateReceivePort.sendPort);

    final StreamIterator<dynamic> it = StreamIterator(isolateReceivePort);
    if (!await it.moveNext()) return;
    final replyPort = it.current as SendPort;

    Interpreter? interpreter;
    try {
      final options = InterpreterOptions()
        ..threads = 4; // High-performance thread count for background inference
      
      interpreter = Interpreter.fromBuffer(modelData, options: options);
      interpreter.allocateTensors();
      replyPort.send('ready');
    } catch (e) {
      debugPrint('[SpoofWorker Isolate] CRITICAL load failed: $e');
    }

    while (await it.moveNext()) {
      final message = it.current;
      if (message is! Map) continue;
      final cmd = message['cmd'] as SpoofCommand;
      
      if (cmd == SpoofCommand.stop) {
        interpreter?.close();
        Isolate.exit();
        break;
      }

      if (cmd == SpoofCommand.detect && interpreter != null) {
        final data = message['data'] as SpoofFrameData;
        final sw = Stopwatch()..start();
        
        try {
          // 1. Optimized Face-Targeted Preprocessing
          final input = _preprocessFaceCrop(data);
          final preprocessTime = sw.elapsedMilliseconds;

          if (data.debugPath != null) {
            _saveDebugImage(input, data.debugPath!);
          }

          sw.reset();
          sw.start();
          final output = List.filled(1 * 6 * 8400, 0.0).reshape([1, 6, 8400]);
          interpreter.runForMultipleInputs([input.reshape([1, 640, 640, 3])], {0: output});
          final inferenceTime = sw.elapsedMilliseconds;
          
          debugPrint('[SpoofWorker Isolate] Perf: Preprocess ${preprocessTime}ms | Inference ${inferenceTime}ms');

          replyPort.send(_parseYoloOutput(output[0]));
        } catch (e, st) {
          debugPrint('[SpoofWorker Isolate] Runtime Error: $e\n$st');
          replyPort.send(SpoofWorkerResult(isReal: true, confidence: 0.0));
        }
      }
    }
  }

  static Float32List _preprocessFaceCrop(SpoofFrameData data) {
    final input = Float32List(1 * 640 * 640 * 3);
    final yPlane = data.planes[0];
    final uPlane = data.planes[1];
    final vPlane = data.planes[2];

    final int frameWidth = data.width;
    final int frameHeight = data.height;
    final int yRowStride = data.bytesPerRow[0];
    final int uvRowStride = data.bytesPerRow[1];
    final int uvPixelStride = data.bytesPerPixel[1];

    // Determine the crop area (Default to full frame if no cropRect provided)
    int cropL = 0;
    int cropT = 0;
    int cropW = frameWidth;
    int cropH = frameHeight;

    if (data.cropRect != null) {
      // Apply safety margin (20%) to the crop to keep some context
      final rect = data.cropRect!;
      final marginW = (rect[2] - rect[0]) * 0.2;
      final marginH = (rect[3] - rect[1]) * 0.2;
      
      cropL = (rect[0] - marginW).toInt().clamp(0, frameWidth - 10);
      cropT = (rect[1] - marginH).toInt().clamp(0, frameHeight - 10);
      cropW = (rect[2] - rect[0] + 2 * marginW).toInt().clamp(10, frameWidth - cropL);
      cropH = (rect[3] - rect[1] + 2 * marginH).toInt().clamp(10, frameHeight - cropT);
    }

    final double scaleX = cropW / 640.0;
    final double scaleY = cropH / 640.0;

    final Int32List xTable = Int32List(640);
    for (int w = 0; w < 640; w++) {
      xTable[w] = (w * scaleX).toInt();
    }

    int pixelIndex = 0;
    for (int h = 0; h < 640; h++) {
      final int srcY = cropT + (h * scaleY).toInt();
      final int yRowBase = srcY * yRowStride;
      final int uvRowBase = (srcY >> 1) * uvRowStride;

      for (int w = 0; w < 640; w++) {
        final int srcX = cropL + xTable[w];
        final int yIndex = yRowBase + srcX;
        final int uvIndex = uvRowBase + ((srcX >> 1) * uvPixelStride);

        // Standard YUV to RGB conversion
        final int yVal = yPlane[yIndex];
        final int uVal = (uPlane.length > uvIndex) ? uPlane[uvIndex] - 128 : 0;
        final int vVal = (vPlane.length > uvIndex) ? vPlane[uvIndex] - 128 : 0;

        int r = (yVal + 1.402 * vVal).toInt().clamp(0, 255);
        int g = (yVal - 0.344136 * uVal - 0.714136 * vVal).toInt().clamp(0, 255);
        int b = (yVal + 1.772 * uVal).toInt().clamp(0, 255);

        // Normalize to [0.0, 1.0] (Standard for YOLOv8 float32)
        input[pixelIndex++] = r / 255.0;
        input[pixelIndex++] = g / 255.0;
        input[pixelIndex++] = b / 255.0;
      }
    }
    return input;
  }

  static void _saveDebugImage(Float32List normalizedData, String path) {
    try {
      final image = img_lib.Image(width: 640, height: 640);
      int index = 0;
      for (int y = 0; y < 640; y++) {
        for (int x = 0; x < 640; x++) {
          final r = (normalizedData[index++] * 255).toInt().clamp(0, 255);
          final g = (normalizedData[index++] * 255).toInt().clamp(0, 255);
          final b = (normalizedData[index++] * 255).toInt().clamp(0, 255);
          image.setPixelRgb(x, y, r, g, b);
        }
      }
      final jpeg = img_lib.encodeJpg(image);
      File(path).writeAsBytesSync(jpeg);
    } catch (e) {
      debugPrint('[SpoofWorker Isolate] Debug save failed: $e');
    }
  }

  static SpoofWorkerResult _parseYoloOutput(List<List<double>> output) {
    final List<double> peaks = List.filled(6, 0.0);
    for (int ch = 0; ch < 6; ch++) {
      double maxVal = 0.0;
      for (int i = 0; i < 8400; i++) {
        if (output[ch][i] > maxVal) maxVal = output[ch][i];
      }
      peaks[ch] = maxVal;
    }
    
    debugPrint('[SpoofWorker Isolate] Raw Peak Channels: [0]: ${peaks[0].toStringAsFixed(3)}, [1]: ${peaks[1].toStringAsFixed(3)}, [2]: ${peaks[2].toStringAsFixed(3)}, [3]: ${peaks[3].toStringAsFixed(3)}, [4]: ${peaks[4].toStringAsFixed(3)}, [5]: ${peaks[5].toStringAsFixed(3)}');

    // --- HEURISTIC: "The Index 3 Rule" ---
    // User diagnostic tests show that Index 3 is the most reliable signal for
    // "Authentic Face Fullness". Above 90% is Real, below is Spoof.
    final index3Score = peaks[3];

    if (index3Score > 0.90) {
      return SpoofWorkerResult(isReal: true, confidence: index3Score, diagnostics: peaks);
    } else {
      return SpoofWorkerResult(isReal: false, confidence: index3Score, diagnostics: peaks);
    }
  }
}
