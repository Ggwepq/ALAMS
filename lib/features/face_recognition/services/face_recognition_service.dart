import 'dart:io';
import 'dart:math' as math;

import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// FaceNet standard input size (160×160)
const int kInputSize = 160;

/// How many embeddings to capture per person during registration.
const int kEmbeddingsPerPerson = 5;

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

  // ---------------------------------------------------------------------------
  // PREPROCESSING
  // ---------------------------------------------------------------------------

  /// Converts a [CameraImage] (YUV420) to a 160×160 [img.Image] cropped to the
  /// face area. Handles camera sensor rotation automatically.
  ///
  /// Pass [sensorRotation] as the degrees the camera image needs to be rotated
  /// to appear upright (typically 90 on most Android devices).
  static img.Image? preprocessCameraImage(Map<String, dynamic> args) {
    try {
      final CameraImage cameraImage = args['image'];
      final Rect? cropRect = args['cropRect'];
      final int sensorRotation = args['sensorRotation'] ?? 90; // ✅ FIX: Handle rotation

      final width = cameraImage.width;
      final height = cameraImage.height;

      final yPlane = cameraImage.planes[0];
      final uPlane = cameraImage.planes[1];
      final vPlane = cameraImage.planes[2];

      final int yRowStride = yPlane.bytesPerRow;
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      // -----------------------------------------------------------------------
      // Step 1 – Convert full YUV frame to RGB
      // -----------------------------------------------------------------------
      final fullImage = img.Image(width: width, height: height);

      for (int srcY = 0; srcY < height; srcY++) {
        for (int srcX = 0; srcX < width; srcX++) {
          final int yIndex = srcY * yRowStride + srcX;
          final int uvIndex =
              (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

          if (yIndex >= yPlane.bytes.length ||
              uvIndex >= uPlane.bytes.length ||
              uvIndex >= vPlane.bytes.length) continue;

          final int yVal = yPlane.bytes[yIndex] & 0xFF;
          final int uVal = uPlane.bytes[uvIndex] & 0xFF;
          final int vVal = vPlane.bytes[uvIndex] & 0xFF;

          final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
          final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
              .clamp(0, 255)
              .toInt();
          final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();

          fullImage.setPixelRgb(srcX, srcY, r, g, b);
        }
      }

      // -----------------------------------------------------------------------
      // Step 2 – Rotate to correct sensor orientation ✅ FIX
      // -----------------------------------------------------------------------
      final uprightImage = sensorRotation != 0
          ? img.copyRotate(fullImage, angle: sensorRotation)
          : fullImage;

      // After rotation, effective dimensions may have swapped
      final int uprightWidth = uprightImage.width;
      final int uprightHeight = uprightImage.height;

      // -----------------------------------------------------------------------
      // Step 3 – Crop to face region with padding
      // -----------------------------------------------------------------------
      img.Image faceImage;

      if (cropRect != null) {
        // 🛡️ 15% padding to ensure peripheral features are captured
        final double paddingX = cropRect.width * 0.15;
        final double paddingY = cropRect.height * 0.15;

        final int startX =
            (cropRect.left - paddingX).toInt().clamp(0, uprightWidth - 1);
        final int startY =
            (cropRect.top - paddingY).toInt().clamp(0, uprightHeight - 1);
        final int cropW = (cropRect.width + (paddingX * 2))
            .toInt()
            .clamp(1, uprightWidth - startX);
        final int cropH = (cropRect.height + (paddingY * 2))
            .toInt()
            .clamp(1, uprightHeight - startY);

        faceImage = img.copyCrop(uprightImage,
            x: startX, y: startY, width: cropW, height: cropH);
      } else {
        faceImage = uprightImage;
      }

      // -----------------------------------------------------------------------
      // Step 4 – Resize to FaceNet input (160×160)
      // -----------------------------------------------------------------------
      final resized =
          img.copyResize(faceImage, width: kInputSize, height: kInputSize);

      // -----------------------------------------------------------------------
      // Step 5 – Brightness / contrast normalisation ✅ FIX: always apply
      // -----------------------------------------------------------------------
      _calibrateBrightness(resized);

      // Optional debug save
      final String? debugPath = args['debugPath'];
      if (debugPath != null) {
        File(debugPath).writeAsBytesSync(img.encodeJpg(resized));
        debugPrint('[FaceRecognition] Debug image saved: $debugPath');
      }

      return resized;
    } catch (e) {
      debugPrint('[FaceRecognition] Preprocessing error: $e');
      return null;
    }
  }

  /// Histogram stretching for contrast normalisation.
  /// ✅ FIX: Removed the `maxV < 200` gate — harsh lighting also distorts faces.
  static void _calibrateBrightness(img.Image image) {
    num minV = 255;
    num maxV = 0;

    for (final pixel in image) {
      final lum = (0.299 * pixel.r) + (0.587 * pixel.g) + (0.114 * pixel.b);
      if (lum < minV) minV = lum;
      if (lum > maxV) maxV = lum;
    }

    // ✅ FIX: Apply whenever there is enough dynamic range, regardless of brightness level
    if (maxV - minV > 10) {
      final factor = 255.0 / (maxV - minV);
      for (final pixel in image) {
        pixel.r = ((pixel.r - minV) * factor).clamp(0, 255);
        pixel.g = ((pixel.g - minV) * factor).clamp(0, 255);
        pixel.b = ((pixel.b - minV) * factor).clamp(0, 255);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // EMBEDDING
  // ---------------------------------------------------------------------------

  /// Generate a normalised FaceNet embedding from a preprocessed 160×160 image.
  List<double>? generateEmbedding(img.Image faceImage) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      final resizedImage =
          img.copyResize(faceImage, width: kInputSize, height: kInputSize);

      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final embeddingSize = outputShape.last;

      final input = List.generate(
        1,
        (_) => List.generate(
          kInputSize,
          (h) => List.generate(
            kInputSize,
            (w) {
              final pixel = resizedImage.getPixel(w, h);
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

      return _l2Normalise(output[0]);
    } catch (e) {
      debugPrint('[FaceRecognition] Embedding error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // ✅ NEW: MULTI-EMBEDDING REGISTRATION HELPERS
  // ---------------------------------------------------------------------------

  /// Average [embeddings] into a single representative embedding.
  ///
  /// Call this after collecting [kEmbeddingsPerPerson] embeddings during
  /// registration so that the stored face vector covers lighting/angle variation.
  ///
  /// Example usage:
  /// ```dart
  /// final samples = <List<double>>[];
  /// // ... capture kEmbeddingsPerPerson frames and generate an embedding each time
  /// final averaged = FaceRecognitionService.averageEmbeddings(samples);
  /// // Store averaged in your database instead of a single sample
  /// ```
  static List<double> averageEmbeddings(List<List<double>> embeddings) {
    assert(embeddings.isNotEmpty, 'Need at least one embedding to average.');
    final size = embeddings[0].length;
    final avg = List.filled(size, 0.0);

    for (final emb in embeddings) {
      for (int i = 0; i < size; i++) {
        avg[i] += emb[i];
      }
    }

    final mean = avg.map((v) => v / embeddings.length).toList();
    return _l2Normalise(mean);
  }

  /// Returns true when [embeddings] has reached [kEmbeddingsPerPerson] samples,
  /// indicating registration capture is complete.
  static bool isRegistrationComplete(List<List<double>> embeddings) =>
      embeddings.length >= kEmbeddingsPerPerson;

  // ---------------------------------------------------------------------------
  // MATH UTILITIES
  // ---------------------------------------------------------------------------

  /// L2-normalise a vector so all embeddings live on the unit hypersphere.
  static List<double> _l2Normalise(List<double> v) {
    double norm = 0;
    for (final x in v) norm += x * x;
    norm = math.sqrt(norm);
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  /// Cosine distance in [0, 2]. Lower = more similar.
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

  // ---------------------------------------------------------------------------
  // RECOGNITION
  // ---------------------------------------------------------------------------

  /// Find the best match in [knownFaces] for [liveEmbedding].
  ///
  /// Thresholds are slightly relaxed from the original to reduce false rejections
  /// now that we store averaged multi-sample embeddings. Tighten again if spoofing
  /// becomes a concern after fixing rotation + multi-embedding registration.
  static RecognitionResult findBestMatch(
    List<double> liveEmbedding,
    List<MapEntry<String, List<double>>> knownFaces, {
    double threshold = 0.45,   // ✅ FIX: relaxed slightly (was 0.40)
    double minMargin = 0.08,   // ✅ FIX: relaxed slightly (was 0.10)
  }) {
    if (knownFaces.isEmpty) {
      return const RecognitionResult(
          label: 'Unknown', distance: 1.0, isRecognized: false);
    }

    // 🛡️ QUALITY GUARD: Reject low-norm (blank / occluded face) embeddings
    double liveNorm = 0;
    for (final v in liveEmbedding) liveNorm += v * v;
    if (liveNorm < 0.5) {
      debugPrint(
          '[FaceRecognition] Rejection: norm too low ($liveNorm)');
      return const RecognitionResult(
          label: 'Unknown', distance: 1.0, isRecognized: false);
    }

    double bestDist = double.maxFinite;
    double secondDist = double.maxFinite;
    String bestLabel = 'Unknown';

    for (final entry in knownFaces) {
      final dist = cosineDistance(liveEmbedding, entry.value);
      if (dist < bestDist) {
        secondDist = bestDist;
        bestDist = dist;
        bestLabel = entry.key;
      } else if (dist < secondDist) {
        secondDist = dist;
      }
    }

    // 🛡️ NO-COMPETITION GUARD (single registered user)
    if (knownFaces.length == 1 && bestDist > 0.35) {
      debugPrint(
          '[FaceRecognition] Single-user rejection: $bestDist > 0.35');
      return RecognitionResult(
        label: 'Unknown',
        distance: bestDist,
        isRecognized: false,
      );
    }

    final margin = secondDist - bestDist;

    // 🛡️ ADAPTIVE SECURITY
    // Accept if: below threshold AND (nearly perfect OR clearly better than 2nd best)
    final bool isStrongMatch = bestDist < 0.30; // ✅ FIX: relaxed from 0.25
    final isRecognized =
        bestDist < threshold && (isStrongMatch || margin >= minMargin);

    debugPrint(
        '[FaceRecognition] best=$bestDist margin=$margin '
        '(minMargin=$minMargin) strong=$isStrongMatch → recognized=$isRecognized');

    return RecognitionResult(
      label: isRecognized ? bestLabel : 'Unknown',
      distance: bestDist,
      isRecognized: isRecognized,
    );
  }

  // ---------------------------------------------------------------------------
  // DUPLICATE CHECK
  // ---------------------------------------------------------------------------

  /// Check whether [newEmbedding] is too similar to any existing registered face.
  /// Used during registration to prevent duplicate enrollments.
  static String? checkDuplicateEmbedding(
    List<double> newEmbedding,
    List<MapEntry<String, List<double>>> existingFaces, {
    double duplicateThreshold = 0.30,
  }) {
    for (final entry in existingFaces) {
      final dist = cosineDistance(newEmbedding, entry.value);
      if (dist < duplicateThreshold) {
        debugPrint(
            '[FaceRecognition] Duplicate detected: ${entry.key} (dist=$dist)');
        return entry.key;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  void dispose() {
    _interpreter?.close();
    _isLoaded = false;
    _instance = null;
  }
}