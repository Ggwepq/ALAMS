import 'dart:io';
import 'dart:math' as math;

import 'dart:ui';
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

  /// Converts a [CameraImage] (YUV420) to a 160x160 [img.Image] isolated to the face area.
  /// Static so it can run inside a compute isolate.
  static img.Image? preprocessCameraImage(Map<String, dynamic> args) {
    try {
      final CameraImage cameraImage = args['image'];
      final Rect? cropRect = args['cropRect'];

      final width = cameraImage.width;
      final height = cameraImage.height;
      
      final yPlane = cameraImage.planes[0];
      final uPlane = cameraImage.planes[1];
      final vPlane = cameraImage.planes[2];

      final int yRowStride = yPlane.bytesPerRow;
      final int uvRowStride = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      // Define dimensions to scan
      int startX = 0;
      int startY = 0;
      int scanWidth = width;
      int scanHeight = height;

      if (cropRect != null) {
        // 🛡️ Add 10% padding to ensure peripheral features are captured
        final double paddingX = cropRect.width * 0.10;
        final double paddingY = cropRect.height * 0.10;
        
        startX = (cropRect.left - paddingX).toInt().clamp(0, width - 1);
        startY = (cropRect.top - paddingY).toInt().clamp(0, height - 1);
        scanWidth = (cropRect.width + (paddingX * 2)).toInt().clamp(1, width - startX);
        scanHeight = (cropRect.height + (paddingY * 2)).toInt().clamp(1, height - startY);
      }

      // Target size for FaceNet
      const int targetSize = 160;
      final double scaleX = scanWidth / targetSize;
      final double scaleY = scanHeight / targetSize;


      final processedImage = img.Image(width: targetSize, height: targetSize);

      for (int h = 0; h < targetSize; h++) {
        final int srcY = startY + (h * scaleY).toInt();
        for (int w = 0; w < targetSize; w++) {
          final int srcX = startX + (w * scaleX).toInt();

          final int yIndex = srcY * yRowStride + srcX;
          final int uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

          // Extra safety check for bounds
          if (yIndex >= yPlane.bytes.length || uvIndex >= uPlane.bytes.length) continue;

          final int yVal = yPlane.bytes[yIndex] & 0xFF;
          final int uVal = uPlane.bytes[uvIndex] & 0xFF;
          final int vVal = vPlane.bytes[uvIndex] & 0xFF;

          final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255).toInt();
          final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).clamp(0, 255).toInt();
          final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255).toInt();

          processedImage.setPixelRgb(w, h, r, g, b);
        }
      }

      // DEBUG: Save the cropped face to disk if requested
      final String? debugPath = args['debugPath'];
      // 🛡️ Brightness Equalization: Normalize light levels to help the AI "see" in shadows
      _calibrateBrightness(processedImage);

      if (debugPath != null) {
        File(debugPath).writeAsBytesSync(img.encodeJpg(processedImage));
        debugPrint('[FaceRecognition] Debug image saved: $debugPath');
      }

      return processedImage;
    } catch (e) {
      debugPrint('[FaceRecognition] Preprocessing error: $e');
      return null;
    }
  }

  /// Stretches the image histogram to improve contrast in low light.
  static void _calibrateBrightness(img.Image image) {
    num minV = 255;
    num maxV = 0;

    for (final pixel in image) {
      final lum = (0.299 * pixel.r) + (0.587 * pixel.g) + (0.114 * pixel.b);
      if (lum < minV) minV = lum;
      if (lum > maxV) maxV = lum;
    }

    // Only stretch if there's enough range to work with and it's actually dim
    if (maxV - minV > 10 && maxV < 200) {
      final factor = 255.0 / (maxV - minV);
      for (final pixel in image) {
        pixel.r = ((pixel.r - minV) * factor).clamp(0, 255);
        pixel.g = ((pixel.g - minV) * factor).clamp(0, 255);
        pixel.b = ((pixel.b - minV) * factor).clamp(0, 255);
      }
    }
  }

  /// Generate a normalised FaceNet embedding from a preprocessed 160×160 image.
  List<double>? generateEmbedding(img.Image faceImage) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      // Ensure image is correct size for FaceNet
      final resizedImage = img.copyResize(faceImage, width: kInputSize, height: kInputSize);
      
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
    double threshold = 0.55,  // Balanced for mobile deployment (0.50-0.60 is standard)
    double minMargin = 0.05,  // Reduced to handle siblings or similar features
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
    
    // 🛡️ ADAPTIVE MARGIN: If the best match is exceptionally strong (< 0.35), 
    // we ignore the margin safety check to ensure recall.
    final bool isStrongMatch = bestDist < 0.35;
    final isRecognized = bestDist < threshold && (isStrongMatch || margin >= minMargin);

    debugPrint('[FaceRecognition] best=$bestDist margin=$margin strong=$isStrongMatch → recognized=$isRecognized');

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
    double duplicateThreshold = 0.30, // stricter check to prevent false positives
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
