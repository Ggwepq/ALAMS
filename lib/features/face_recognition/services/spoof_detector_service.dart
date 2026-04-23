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
  Future<SpoofWorkerResult> detectSpoof(CameraImage image, {String? debugPath, Rect? cropRect, int sensorOrientation = 0}) async {
    if (_worker == null) {
      return SpoofWorkerResult(isReal: true, confidence: 0.0);
    }

    List<double>? transformedRect;
    if (cropRect != null) {
      // Map UI Rect (Rotated) back to Sensor coordinates
      // Logic: If sensor is 270 deg (Portrait Front Cam):
      // UI Left -> Sensor Top
      // UI Top -> Sensor (Width - Right)
      if (sensorOrientation == 270) {
        transformedRect = [
          cropRect.top, // Sensor Left
          image.height - cropRect.right, // Sensor Top
          cropRect.bottom, // Sensor Right
          image.height - cropRect.left, // Sensor Bottom
        ];
      } else if (sensorOrientation == 90) {
        transformedRect = [
          image.width - cropRect.bottom, // Sensor Left
          cropRect.left, // Sensor Top
          image.width - cropRect.top, // Sensor Right
          cropRect.right, // Sensor Bottom
        ];
      } else {
        transformedRect = [cropRect.left, cropRect.top, cropRect.right, cropRect.bottom];
      }
    }

    // Convert planes to transferable ByteData
    final frameData = SpoofFrameData(
      planes: image.planes.map((p) => p.bytes).toList(),
      width: image.width,
      height: image.height,
      bytesPerPixel: image.planes.map((p) => p.bytesPerPixel ?? 1).toList(),
      bytesPerRow: image.planes.map((p) => p.bytesPerRow).toList(),
      debugPath: debugPath,
      cropRect: transformedRect,
    );

    return await _worker!.detect(frameData);
  }

  void dispose() {
    _worker?.dispose();
    _worker = null;
  }
}
