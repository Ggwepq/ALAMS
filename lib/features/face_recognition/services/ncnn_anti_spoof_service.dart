import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import '../models/spoof_result.dart';

/// Native NCNN-based anti-spoofing service.
/// Uses the official MiniFASNet NCNN models via Android platform channels.
class NcnnAntiSpoofService {
  static const _channel = MethodChannel('com.example.alams/antispoof');
  static final NcnnAntiSpoofService instance = NcnnAntiSpoofService._();

  bool _initialized = false;
  bool _busy = false;

  NcnnAntiSpoofService._();

  bool get isLoaded => _initialized;
  bool get isBusy => _busy;

  /// Initialize the native NCNN engine (loads models from Android assets).
  Future<void> loadModel() async {
    if (_initialized) return;
    try {
      debugPrint('[NcnnAntiSpoof] Initializing native NCNN engine...');
      final result = await _channel.invokeMethod<bool>('init');
      _initialized = result ?? false;
      debugPrint('[NcnnAntiSpoof] Engine initialized: $_initialized');
    } catch (e) {
      debugPrint('[NcnnAntiSpoof] Init failed: $e');
    }
  }

  /// Detect spoof from a camera frame using native NCNN inference.
  Future<SpoofResult> detectSpoof(
    CameraImage image, {
    String? debugPath,
    Rect? cropRect,
    int sensorOrientation = 0,
  }) async {
    if (!_initialized || _busy) {
      return SpoofResult(isReal: true, confidence: 0.0);
    }

    _busy = true;
    try {
      // Convert YUV_420_888 to NV21 byte array
      final nv21 = _yuv420ToNv21(image);

      // Calculate face box in sensor coordinates
      int left = 0, top = 0, right = image.width, bottom = image.height;
      if (cropRect != null) {
        left = cropRect.left.toInt();
        top = cropRect.top.toInt();
        right = cropRect.right.toInt();
        bottom = cropRect.bottom.toInt();

        // Clamp to valid range
        left = left.clamp(0, image.width - 1);
        top = top.clamp(0, image.height - 1);
        right = right.clamp(left + 1, image.width);
        bottom = bottom.clamp(top + 1, image.height);
      }

      int ncnnOrientation;
      if (sensorOrientation == 270) {
        ncnnOrientation = 7; 
      } else if (sensorOrientation == 90) {
        ncnnOrientation = 6; 
      } else {
        ncnnOrientation = 1; 
      }

      final double threshold = 0.80; // Adjusted for better inclusivity of varied skin tones
      final double confidence = await _channel.invokeMethod<double>('detect', {
        'nv21': nv21,
        'width': image.width,
        'height': image.height,
        'orientation': ncnnOrientation,
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      }) ?? -1.0;

      final bool isReal = confidence > threshold;
      final double conf = confidence.clamp(0.0, 1.0);

      debugPrint('[NcnnAntiSpoof] Score: ${confidence.toStringAsFixed(4)} | '
          '${isReal ? "REAL" : "SPOOF"} (threshold=$threshold)');

      Uint8List? faceCrop;
      try {
        faceCrop = await compute(_extractFaceCrop, {
          'image': image,
          'left': left,
          'top': top,
          'right': right,
          'bottom': bottom,
          'orientation': sensorOrientation,
        });
      } catch (e) {
        debugPrint('[NcnnAntiSpoof] Crop error: $e');
      }

      return SpoofResult(
        isReal: isReal,
        confidence: conf,
        diagnostics: [confidence, threshold],
        faceCrop: faceCrop,
      );
    } catch (e) {
      debugPrint('[NcnnAntiSpoof] Detection error: $e');
      return SpoofResult(isReal: true, confidence: 0.0);
    } finally {
      _busy = false;
    }
  }

  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;
    final nv21 = Uint8List(ySize + uvSize);

    final yPlane = image.planes[0];
    final yRowStride = yPlane.bytesPerRow;
    if (yRowStride == width) {
      nv21.setRange(0, ySize, yPlane.bytes);
    } else {
      for (int row = 0; row < height; row++) {
        nv21.setRange(
          row * width,
          row * width + width,
          yPlane.bytes,
          row * yRowStride,
        );
      }
    }

    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    int uvIndex = ySize;
    for (int row = 0; row < height ~/ 2; row++) {
      for (int col = 0; col < width ~/ 2; col++) {
        final int srcOffset = row * uvRowStride + col * uvPixelStride;
        if (srcOffset < vPlane.bytes.length && srcOffset < uPlane.bytes.length) {
          nv21[uvIndex++] = vPlane.bytes[srcOffset]; 
          nv21[uvIndex++] = uPlane.bytes[srcOffset]; 
        } else {
          nv21[uvIndex++] = 128;
          nv21[uvIndex++] = 128;
        }
      }
    }

    return nv21;
  }

  /// Extracts and rotates the face crop for UI preview.
  /// Runs in a background isolate via [compute].
  static Uint8List? _extractFaceCrop(Map<String, dynamic> params) {
    try {
      final CameraImage image = params['image'];
      final int left = params['left'];
      final int top = params['top'];
      final int right = params['right'];
      final int bottom = params['bottom'];
      final int orientation = params['orientation'];

      final int width = image.width;
      final int height = image.height;
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];

      final int yRowStride = yPlane.bytesPerRow;
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      // 1. Convert only the necessary area to RGB img.Image
      final cropW = right - left;
      final cropH = bottom - top;
      if (cropW <= 0 || cropH <= 0) return null;

      final faceImg = img.Image(width: cropW, height: cropH);

      for (int y = 0; y < cropH; y++) {
        for (int x = 0; x < cropW; x++) {
          final int srcX = left + x;
          final int srcY = top + y;

          if (srcX >= width || srcY >= height) continue;

          final int yIndex = srcY * yRowStride + srcX;
          final int uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

          if (yIndex >= yPlane.bytes.length || uvIndex >= uPlane.bytes.length) continue;

          final int yVal = yPlane.bytes[yIndex] & 0xFF;
          final int uVal = uPlane.bytes[uvIndex] & 0xFF;
          final int vVal = vPlane.bytes[uvIndex] & 0xFF;

          final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
          final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).clamp(0, 255).toInt();
          final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();

          faceImg.setPixelRgb(x, y, r, g, b);
        }
      }

      // 2. Rotate based on sensor orientation to make it upright
      img.Image orientedImg;
      if (orientation == 270) {
        orientedImg = img.copyRotate(faceImg, angle: 270);
      } else if (orientation == 90) {
        orientedImg = img.copyRotate(faceImg, angle: 90);
      } else {
        orientedImg = faceImg;
      }

      // 3. Encode to JPG for Image.memory
      return Uint8List.fromList(img.encodeJpg(orientedImg, quality: 70));
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    try {
      _channel.invokeMethod('destroy');
    } catch (_) {}
    _initialized = false;
  }
}
