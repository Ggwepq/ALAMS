import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Commands sent to the [SpoofWorker].
enum SpoofCommand { detect, stop }

/// Data structure for passing camera frame data to the isolate.
class SpoofFrameData {
  final List<Uint8List> planes;
  final int width;
  final int height;
  final List<int> bytesPerPixel;
  final List<int> bytesPerRow;

  SpoofFrameData({
    required this.planes,
    required this.width,
    required this.height,
    required this.bytesPerPixel,
    required this.bytesPerRow,
  });
}

/// The result returned by the worker.
class SpoofWorkerResult {
  final bool isReal;
  final double confidence;
  
  SpoofWorkerResult({required this.isReal, required this.confidence});
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

  /// Spawn the worker isolate.
  /// [modelData] is the bytecode of the anti-spoofing model.
  static Future<SpoofWorker> spawn(Uint8List modelData) async {
    final handshakePort = ReceivePort();
    final RootIsolateToken? token = RootIsolateToken.instance;
    
    debugPrint('[SpoofWorker] Spawning background isolate...');
    
    await Isolate.spawn(_isolateMain, {
      'handshakePort': handshakePort.sendPort,
      'token': token,
      'modelData': modelData,
    });
    
    // First message from isolate is its SendPort
    final isolateSendPort = await handshakePort.first as SendPort;
    final worker = SpoofWorker(isolateSendPort);
    
    // Send the worker's persistent receive port to the isolate for replies
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

  /// Perform detection in the background isolate.
  Future<SpoofWorkerResult> detect(SpoofFrameData data) async {
    if (!_ready.isCompleted) {
      // Still warming up
      return SpoofWorkerResult(isReal: true, confidence: 0.0);
    }
    
    if (_pendingTask != null) {
      // Throttle: Skip frame if previous inference is still in progress
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

    // Get the ReplyPort for the specific SpoofWorker instance
    final replyPort = await isolateReceivePort.first as SendPort;

    Interpreter? interpreter;
    
    try {
      debugPrint('[SpoofWorker Isolate] Init: Loading interpreter from buffer...');
      
      // We use fromBuffer because it's the most robust way across isolates
      interpreter = Interpreter.fromBuffer(
        modelData,
        options: InterpreterOptions()..threads = 4,
      );
      
      debugPrint('[SpoofWorker Isolate] Init: Model loaded successfully. Input: ${interpreter.getInputTensor(0).shape}');
      replyPort.send('ready');
    } catch (e) {
      debugPrint('[SpoofWorker Isolate] CRITICAL: Model load failed: $e');
    }

    await for (final message in isolateReceivePort) {
      if (message is! Map) continue;
      final cmd = message['cmd'] as SpoofCommand;
      
      if (cmd == SpoofCommand.stop) {
        interpreter?.close();
        Isolate.exit();
      }

      if (cmd == SpoofCommand.detect && interpreter != null) {
        final data = message['data'] as SpoofFrameData;
        
        try {
          // 1. Optimized One-Pass Preprocessing
          final input = _preprocessOptimized(data);
          
          // 2. Inference
          final output = List.filled(1 * 6 * 8400, 0.0).reshape([1, 6, 8400]);
          interpreter.run(input, output);
          
          // 3. Post-processing
          final result = _parseYoloOutput(output[0]);
          
          // Reply with results
          replyPort.send(result);
        } catch (e) {
          debugPrint('[SpoofWorker Isolate] Inference Error: $e');
          replyPort.send(SpoofWorkerResult(isReal: true, confidence: 0.0));
        }
      }
    }
  }

  static Float32List _preprocessOptimized(SpoofFrameData data) {
    final input = Float32List(1 * 640 * 640 * 3);
    final yPlane = data.planes[0];
    final uPlane = data.planes[1];
    final vPlane = data.planes[2];

    final int width = data.width;
    final int height = data.height;
    final int yRowStride = data.bytesPerRow[0];
    final int uvRowStride = data.bytesPerRow[1];
    final int uvPixelStride = data.bytesPerPixel[1];

    final double scaleX = width / 640.0;
    final double scaleY = height / 640.0;

    int pixelIndex = 0;

    for (int h = 0; h < 640; h++) {
      final int srcY = (h * scaleY).toInt();
      for (int w = 0; w < 640; w++) {
        final int srcX = (w * scaleX).toInt();

        final int yIndex = srcY * yRowStride + srcX;
        final int uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

        final int yVal = yPlane[yIndex] & 0xFF;
        final int uVal = uPlane[uvIndex] & 0xFF;
        final int vVal = vPlane[uvIndex] & 0xFF;

        final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
        final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).clamp(0, 255).toInt();
        final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();

        input[pixelIndex++] = r / 255.0;
        input[pixelIndex++] = g / 255.0;
        input[pixelIndex++] = b / 255.0;
      }
    }
    return input;
  }

  static SpoofWorkerResult _parseYoloOutput(List<List<double>> output) {
    double maxRealScore = 0.0;
    double maxFakeScore = 0.0;

    for (int i = 0; i < 8400; i++) {
      final fakeScore = output[4][i];
      final realScore = output[5][i];

      if (realScore > maxRealScore) maxRealScore = realScore;
      if (fakeScore > maxFakeScore) maxFakeScore = fakeScore;
    }

    if (maxFakeScore > 0.65 && maxFakeScore > maxRealScore) {
      return SpoofWorkerResult(isReal: false, confidence: maxFakeScore);
    }
    return SpoofWorkerResult(isReal: true, confidence: maxRealScore);
  }
}
