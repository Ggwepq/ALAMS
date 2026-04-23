import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'spoof_worker.dart';

/// Proxy service for detecting face spoofs using a background [SpoofWorker].
class SpoofDetectorService {
  static final SpoofDetectorService instance = SpoofDetectorService._init();
  SpoofWorker? _worker;

  SpoofDetectorService._init();

  bool get isLoaded => _worker != null;
  bool get isBusy => _worker?.isBusy ?? false;

  /// Initialize the background worker by first loading the model data into memory.
  Future<void> loadModel() async {
    if (_worker != null) return;
    try {
      debugPrint('[SpoofDetector] Loading model asset into buffer...');
      
      // Load the model as binary data first (Industry standard for reliable isolate loading)
      final data = await rootBundle.load('assets/models/anti-spoofing-model.tflite');
      final buffer = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      
      _worker = await SpoofWorker.spawn(buffer);
      debugPrint('[SpoofDetector] Background worker initialized with model buffer.');
    } catch (e) {
      debugPrint('[SpoofDetector] CRITICAL: Failed to initialize AI worker: $e');
    }
  }

  /// Async detection that offloads everything to the background isolate.
  Future<SpoofWorkerResult> detectSpoof(CameraImage image) async {
    if (_worker == null) {
      return SpoofWorkerResult(isReal: true, confidence: 0.0);
    }

    // Convert planes to transferable ByteData
    final frameData = SpoofFrameData(
      planes: image.planes.map((p) => p.bytes).toList(),
      width: image.width,
      height: image.height,
      bytesPerPixel: image.planes.map((p) => p.bytesPerPixel ?? 1).toList(),
      bytesPerRow: image.planes.map((p) => p.bytesPerRow).toList(),
    );

    return await _worker!.detect(frameData);
  }

  void dispose() {
    _worker?.dispose();
    _worker = null;
  }
}
