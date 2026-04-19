import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// FaceNet standard input size (160×160)
const int kInputSize = 160;

/// Result of a recognition attempt.
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
      debugPrint('[FaceRecognition] FaceNet model loaded.');
    } catch (e) {
      debugPrint('[FaceRecognition] Error loading model: $e');
    }
  }

  bool get isLoaded => _isLoaded;

  /// Converts a [CameraImage] (YUV420) to a 160×160 RGB image for FaceNet.
  /// Static so it can run inside a compute isolate.
  static img.Image? preprocessCameraImage(CameraImage cameraImage) {
    try {
      final planes = cameraImage.planes;
      final yPlane = planes[0];
      final uPlane = planes[1];
      final vPlane = planes[2];

      final width  = cameraImage.width;
      final height = cameraImage.height;

      final yBytes = yPlane.bytes;
      final uBytes = uPlane.bytes;
      final vBytes = vPlane.bytes;

      final yRowStride  = yPlane.bytesPerRow;
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;

      final rawImage = img.Image(width: width, height: height);

      for (int h = 0; h < height; h++) {
        for (int w = 0; w < width; w++) {
          final yIndex  = h * yRowStride + w;
          final uvIndex = (h ~/ 2) * uvRowStride + (w ~/ 2) * uvPixelStride;

          final yVal = yBytes[yIndex] & 0xFF;
          final uVal = uBytes[uvIndex] & 0xFF;
          final vVal = vBytes[uvIndex] & 0xFF;

          final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
          final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).clamp(0, 255).toInt();
          final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();

          rawImage.setPixelRgb(w, h, r, g, b);
        }
      }

      return img.copyResize(rawImage, width: kInputSize, height: kInputSize);
    } catch (e) {
      debugPrint('[FaceRecognition] Preprocessing error: $e');
      return null;
    }
  }

  /// Generate a normalised FaceNet embedding from a preprocessed 160×160 image.
  List<double>? generateEmbedding(img.Image faceImage) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final embeddingSize = outputShape.last;

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

      final output = [List.filled(embeddingSize, 0.0)];
      _interpreter!.run(input, output);

      // L2-normalise the embedding so cosine distance == Euclidean distance.
      return _l2Normalise(output[0]);
    } catch (e) {
      debugPrint('[FaceRecognition] Embedding error: $e');
      return null;
    }
  }

  /// L2-normalise a vector so all embeddings live on the unit hypersphere.
  static List<double> _l2Normalise(List<double> v) {
    double norm = 0;
    for (final x in v) norm += x * x;
    norm = math.sqrt(norm);
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  /// Cosine distance in [0, 2]. Lower = more similar.
  /// Because embeddings are L2-normalised, this equals Euclidean distance.
  static double cosineDistance(List<double> a, List<double> b) {
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot  += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 1.0;
    return 1.0 - (dot / (math.sqrt(normA) * math.sqrt(normB)));
  }

  /// Find the best match in [knownFaces] for [liveEmbedding].
  ///
  /// Uses a two-threshold approach:
  /// - Primary threshold [threshold]: the distance must be below this to count as "recognised".
  /// - Margin guard [minMargin]: the gap between the best and second-best match must be
  ///   at least this large, preventing ambiguous matches near the boundary.
  static RecognitionResult findBestMatch(
    List<double> liveEmbedding,
    List<MapEntry<String, List<double>>> knownFaces, {
    double threshold = 0.40,  // tightened from 0.45
    double minMargin = 0.08,  // second-best must be at least this much worse
  }) {
    if (knownFaces.isEmpty) {
      return const RecognitionResult(label: 'Unknown', distance: 1.0, isRecognized: false);
    }

    double bestDist   = double.maxFinite;
    double secondDist = double.maxFinite;
    String bestLabel  = 'Unknown';

    for (final entry in knownFaces) {
      final dist = cosineDistance(liveEmbedding, entry.value);
      if (dist < bestDist) {
        secondDist = bestDist;
        bestDist   = dist;
        bestLabel  = entry.key;
      } else if (dist < secondDist) {
        secondDist = dist;
      }
    }

    final margin      = secondDist - bestDist;
    final isRecognized = bestDist < threshold && margin >= minMargin;

    debugPrint('[FaceRecognition] best=$bestDist margin=$margin → recognized=$isRecognized');

    return RecognitionResult(
      label:        bestLabel,
      distance:     bestDist,
      isRecognized: isRecognized,
    );
  }

  /// Check whether [newEmbedding] is too similar to any existing registered face.
  ///
  /// Used during registration to prevent duplicate enrollments.
  /// Returns the name of the matching employee, or null if no duplicate found.
  static String? checkDuplicateEmbedding(
    List<double> newEmbedding,
    List<MapEntry<String, List<double>>> existingFaces, {
    double duplicateThreshold = 0.35, // stricter than recognition threshold
  }) {
    for (final entry in existingFaces) {
      final dist = cosineDistance(newEmbedding, entry.value);
      if (dist < duplicateThreshold) {
        debugPrint('[FaceRecognition] Duplicate face detected: ${entry.key} (dist=$dist)');
        return entry.key;
      }
    }
    return null;
  }

  void dispose() {
    _interpreter?.close();
    _isLoaded = false;
    _instance = null;
  }
}
