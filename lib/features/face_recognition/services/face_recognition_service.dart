import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// FaceNet standard input size (usually 160x160)
const int kInputSize = 160;

/// Result of a recognition
class RecognitionResult {
  final String label;
  final double distance;
  final bool isRecognized;

  const RecognitionResult({
    required this.label,
    required this.distance,
    required this.isRecognized,
  });
}

class FaceRecognitionService {
  static FaceRecognitionService? _instance;
  static FaceRecognitionService get instance =>
      _instance ??= FaceRecognitionService._();

  Interpreter? _interpreter;
  bool _isLoaded = false;

  FaceRecognitionService._();

  Future<void> loadModel() async {
    if (_isLoaded) return;
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/models/facenet.tflite',
        options: InterpreterOptions()..threads = 4,
      );
      _isLoaded = true;
      debugPrint('[FaceRecognition] FaceNet model loaded successfully.');
    } catch (e) {
      debugPrint('[FaceRecognition] Error loading model: $e');
    }
  }

  bool get isLoaded => _isLoaded;

  /// Converts a [CameraImage] (YUV420) to a 160x160 RGB image for FaceNet.
  /// Static so it can be used in an Isolate via compute.
  static img.Image? preprocessCameraImage(CameraImage cameraImage) {
    try {
      final planes = cameraImage.planes;
      final yPlane = planes[0];
      final uPlane = planes[1];
      final vPlane = planes[2];

      final int width = cameraImage.width;
      final int height = cameraImage.height;

      final yBytes = yPlane.bytes;
      final uBytes = uPlane.bytes;
      final vBytes = vPlane.bytes;

      final yRowStride = yPlane.bytesPerRow;
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;

      final rawImage = img.Image(width: width, height: height);

      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          final yIndex = h * yRowStride + w;
          final uvIndex =
              (h ~/ 2) * uvRowStride + (w ~/ 2) * uvPixelStride;

          final int yVal = yBytes[yIndex] & 0xFF;
          final int uVal = uBytes[uvIndex] & 0xFF;
          final int vVal = vBytes[uvIndex] & 0xFF;

          // YUV to RGB conversion
          int r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
          int g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
              .clamp(0, 255)
              .toInt();
          int b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();

          rawImage.setPixelRgb(w, h, r, g, b);
        }
      }

      // Resize to model input size
      return img.copyResize(rawImage, width: kInputSize, height: kInputSize);
    } catch (e) {
      debugPrint('[FaceRecognition] Error preprocessing image: $e');
      return null;
    }
  }

  /// Generate an embedding from a preprocessed 160x160 image.
  List<double>? generateEmbedding(img.Image faceImage) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      // Get the output tensor shape so it automatically adapts to 
      // FaceNet variants (which output 128 or 512 dimensions).
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final embeddingSize = outputShape.last; 

      // Normalize pixels to [-1, 1] as required by FaceNet (and MobileFaceNet)
      final input = List.generate(
        1,
        (_) => List.generate(
          kInputSize,
          (h) => List.generate(
            kInputSize,
            (w) {
              final pixel = faceImage.getPixel(w, h);
              return [
                (pixel.r / 127.5) - 1.0,
                (pixel.g / 127.5) - 1.0,
                (pixel.b / 127.5) - 1.0,
              ];
            },
          ),
        ),
      );

      // Output array dynamically matched to the model's output size.
      final output = [List.filled(embeddingSize, 0.0)];
      _interpreter!.run(input, output);
      return output[0];
    } catch (e) {
      debugPrint('[FaceRecognition] Error generating embedding: $e');
      return null;
    }
  }

  /// Compute cosine distance (lower = more similar, 0.0 = identical).
  static double cosineDistance(List<double> a, List<double> b) {
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 1.0;
    return 1.0 - (dot / (math.sqrt(normA) * math.sqrt(normB)));
  }

  /// Match a live embedding against a list of stored embeddings.
  /// Returns the closest match if within [threshold].
  static RecognitionResult findBestMatch(
    List<double> liveEmbedding,
    List<MapEntry<String, List<double>>> knownFaces, {
    double threshold = 0.6,
  }) {
    if (knownFaces.isEmpty) {
      return const RecognitionResult(
          label: 'Unknown', distance: 1.0, isRecognized: false);
    }

    double bestDist = double.maxFinite;
    String bestLabel = 'Unknown';

    for (final entry in knownFaces) {
      final dist = cosineDistance(liveEmbedding, entry.value);
      if (dist < bestDist) {
        bestDist = dist;
        bestLabel = entry.key;
      }
    }

    return RecognitionResult(
      label: bestLabel,
      distance: bestDist,
      isRecognized: bestDist < threshold,
    );
  }

  void dispose() {
    _interpreter?.close();
    _isLoaded = false;
    _instance = null;
  }
}
