import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// FaceNet standard input size (160×160)
const int kInputSize = 160;

/// How many embeddings to capture per person during registration.
const int kEmbeddingsPerPerson = 5;

/// Euclidean distance thresholds for FaceNet L2-normalised embeddings.
/// FaceNet paper recommends ~1.06 as the boundary on LFW.
/// Lower value = more similar faces.
///
/// Recognition accept range:   0.0 – 0.90
/// Strong-match floor:         0.60  (bypasses margin check)
/// Duplicate-enrolment guard:  0.60
/// Single-user hard cap:       0.70
const double kRecognitionThreshold = 0.90;
const double kStrongMatchThreshold = 0.60;
const double kMinMargin            = 0.10;
const double kDuplicateThreshold   = 0.60;
const double kSingleUserHardMax    = 0.70;

/// Result of a recognition attempt.
class RecognitionResult {
  final String label;
  final double distance;
  final double confidence; // 0–100 %, higher = more confident
  final bool isRecognized;

  const RecognitionResult({
    required this.label,
    required this.distance,
    required this.confidence,
    required this.isRecognized,
  });
}

class FaceRecognitionService {
  static FaceRecognitionService? _instance;
  static FaceRecognitionService get instance =>
      _instance ??= FaceRecognitionService._();

  Interpreter? _interpreter;

  /// Shared high-accuracy face detector.
  final FaceDetector faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode:      FaceDetectorMode.accurate,
      enableLandmarks:      true,
      enableClassification: true,
      minFaceSize:          0.2,
    ),
  );

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

  /// Converts a [CameraImage] (YUV420) to a 160×160 [img.Image] cropped to
  /// the face region.
  static img.Image? preprocessCameraImage(Map<String, dynamic> args) {
    try {
      final CameraImage cameraImage = args['image'];
      final Rect?  cropRect         = args['cropRect'];
      final Face?  face             = args['face'];
      final int    sensorRotation   = args['sensorRotation'] ?? 270;

      final width  = cameraImage.width;
      final height = cameraImage.height;

      final yPlane = cameraImage.planes[0];
      final uPlane = cameraImage.planes[1];
      final vPlane = cameraImage.planes[2];

      final int yRowStride    = yPlane.bytesPerRow;
      final int uvRowStride   = uPlane.bytesPerRow;
      final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

      // ── Step 1: YUV → RGB ──────────────────────────────────────────────────
      final fullImage = img.Image(width: width, height: height);

      for (int srcY = 0; srcY < height; srcY++) {
        for (int srcX = 0; srcX < width; srcX++) {
          final int yIndex  = srcY * yRowStride + srcX;
          final int uvIndex =
              (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

          if (yIndex  >= yPlane.bytes.length ||
              uvIndex >= uPlane.bytes.length ||
              uvIndex >= vPlane.bytes.length) continue;

          final int yVal = yPlane.bytes[yIndex]  & 0xFF;
          final int uVal = uPlane.bytes[uvIndex] & 0xFF;
          final int vVal = vPlane.bytes[uvIndex] & 0xFF;

          final r = (yVal + 1.402    * (vVal - 128)).clamp(0, 255).toInt();
          final g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
              .clamp(0, 255).toInt();
          final b = (yVal + 1.772    * (uVal - 128)).clamp(0, 255).toInt();

          fullImage.setPixelRgb(srcX, srcY, r, g, b);
        }
      }

      // ── Step 2: Rotate to upright orientation ─────────────────────────────
      final uprightImage = sensorRotation != 0
          ? img.copyRotate(fullImage, angle: sensorRotation)
          : fullImage;

      final int uprightWidth  = uprightImage.width;
      final int uprightHeight = uprightImage.height;

      // ── Step 3: Crop to face region ────────────────────────────────────────
      img.Image faceImage;

      if (face != null) {
        final rect    = face.boundingBox;
        const padding = 20;
        final x = (rect.left.toInt()   - padding).clamp(0, uprightWidth  - 1);
        final y = (rect.top.toInt()    - padding).clamp(0, uprightHeight - 1);
        final w = (rect.width.toInt()  + padding * 2).clamp(1, uprightWidth  - x);
        final h = (rect.height.toInt() + padding * 2).clamp(1, uprightHeight - y);

        faceImage = img.copyCrop(uprightImage, x: x, y: y, width: w, height: h);
      } else if (cropRect != null) {
        final double paddingX = cropRect.width  * 0.15;
        final double paddingY = cropRect.height * 0.15;

        final int startX = (cropRect.left - paddingX).toInt().clamp(0, uprightWidth  - 1);
        final int startY = (cropRect.top  - paddingY).toInt().clamp(0, uprightHeight - 1);
        final int cropW  = (cropRect.width  + paddingX * 2).toInt().clamp(1, uprightWidth  - startX);
        final int cropH  = (cropRect.height + paddingY * 2).toInt().clamp(1, uprightHeight - startY);

        faceImage = img.copyCrop(uprightImage,
            x: startX, y: startY, width: cropW, height: cropH);
      } else {
        faceImage = uprightImage;
      }

      // ── Step 4: Resize to 160×160 ──────────────────────────────────────────
      final resized =
          img.copyResize(faceImage, width: kInputSize, height: kInputSize);

      // ── Step 5: Brightness / contrast normalisation ────────────────────────
      _calibrateBrightness(resized);

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
  static void _calibrateBrightness(img.Image image) {
    num minV = 255;
    num maxV = 0;

    for (final pixel in image) {
      final lum = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
      if (lum < minV) minV = lum;
      if (lum > maxV) maxV = lum;
    }

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

  /// Generate an L2-normalised FaceNet embedding from a 160×160 [img.Image].
  List<double>? generateEmbedding(img.Image faceImage) {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      final resized =
          img.copyResize(faceImage, width: kInputSize, height: kInputSize);

      final outputShape   = _interpreter!.getOutputTensor(0).shape;
      final embeddingSize = outputShape.last;

      final input = List.generate(
        1,
        (_) => List.generate(
          kInputSize,
          (h) => List.generate(
            kInputSize,
            (w) {
              final pixel = resized.getPixel(w, h);
              return [
                (pixel.r.toDouble() - 127.5) / 128.0,
                (pixel.g.toDouble() - 127.5) / 128.0,
                (pixel.b.toDouble() - 127.5) / 128.0,
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
  // ✅ NEW: generateEmbeddingFromFile
  // ---------------------------------------------------------------------------

  /// Reads a still-photo JPEG from [filePath], crops it to the ML Kit
  /// [face] bounding box, runs brightness normalisation, and returns an
  /// L2-normalised FaceNet embedding.
  ///
  /// This is the method called by [RegistrationScreen._capturePose()] after
  /// each [takePicture()] call. Using a clean ISP-processed JPEG gives
  /// dramatically better embedding quality than decoding a raw YUV stream frame.
  ///
  /// Returns `null` if the file cannot be decoded or the model is not loaded.
  Future<List<double>?> generateEmbeddingFromFile(
      String filePath, Face face) async {
    if (!_isLoaded || _interpreter == null) return null;

    try {
      // ── 1. Decode JPEG ─────────────────────────────────────────────────────
      final bytes    = await File(filePath).readAsBytes();
      final rawImage = img.decodeImage(bytes);
      if (rawImage == null) {
        debugPrint('[FaceRecognition] generateEmbeddingFromFile: decode failed');
        return null;
      }

      // ── 2. Crop to ML Kit bounding box + 20 px padding ────────────────────
      const padding = 20;
      final rect = face.boundingBox;
      final x = (rect.left.toInt()   - padding).clamp(0, rawImage.width  - 1);
      final y = (rect.top.toInt()    - padding).clamp(0, rawImage.height - 1);
      final w = (rect.width.toInt()  + padding * 2).clamp(1, rawImage.width  - x);
      final h = (rect.height.toInt() + padding * 2).clamp(1, rawImage.height - y);

      final cropped = img.copyCrop(rawImage, x: x, y: y, width: w, height: h);

      // ── 3. Resize to 160×160 ───────────────────────────────────────────────
      final resized =
          img.copyResize(cropped, width: kInputSize, height: kInputSize);

      // ── 4. Brightness / contrast normalisation ─────────────────────────────
      _calibrateBrightness(resized);

      // ── 5. Run FaceNet ─────────────────────────────────────────────────────
      return generateEmbedding(resized);
    } catch (e) {
      debugPrint('[FaceRecognition] generateEmbeddingFromFile error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // MULTI-EMBEDDING REGISTRATION HELPERS
  // ---------------------------------------------------------------------------

  /// Average [embeddings] into one representative L2-normalised embedding.
  static List<double> averageEmbeddings(List<List<double>> embeddings) {
    assert(embeddings.isNotEmpty, 'Need at least one embedding to average.');
    final size = embeddings[0].length;
    final avg  = List.filled(size, 0.0);

    for (final emb in embeddings) {
      for (int i = 0; i < size; i++) avg[i] += emb[i];
    }

    return _l2Normalise(avg.map((v) => v / embeddings.length).toList());
  }

  /// Returns true when [embeddings] has reached [kEmbeddingsPerPerson] samples.
  static bool isRegistrationComplete(List<List<double>> embeddings) =>
      embeddings.length >= kEmbeddingsPerPerson;

  // ---------------------------------------------------------------------------
  // MATH UTILITIES
  // ---------------------------------------------------------------------------

  /// L2-normalise a vector onto the unit hypersphere.
  static List<double> _l2Normalise(List<double> v) {
    double norm = 0;
    for (final x in v) norm += x * x;
    norm = math.sqrt(norm);
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  /// Euclidean distance between two L2-normalised embeddings.
  /// Range [0, 2]. Lower = more similar.
  static double euclideanDistance(List<double> a, List<double> b) {
    assert(a.length == b.length, 'Embedding size mismatch.');
    double sum = 0;
    for (int i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return math.sqrt(sum);
  }

  // ---------------------------------------------------------------------------
  // RECOGNITION
  // ---------------------------------------------------------------------------

  /// Find the best match in [knownFaces] for [liveEmbedding].
  static RecognitionResult findBestMatch(
    List<double> liveEmbedding,
    List<MapEntry<String, List<double>>> knownFaces, {
    double threshold = kRecognitionThreshold,
    double minMargin = kMinMargin,
  }) {
    if (knownFaces.isEmpty) {
      return const RecognitionResult(
          label: 'Unknown', distance: 2.0, confidence: 0, isRecognized: false);
    }

    // ── 1. QUALITY GUARD ──────────────────────────────────────────────────────
    double liveNorm = 0;
    for (final v in liveEmbedding) liveNorm += v * v;
    if (liveNorm < 0.5) {
      debugPrint('[FaceRecognition] Rejection: norm too low ($liveNorm)');
      return const RecognitionResult(
          label: 'Unknown', distance: 2.0, confidence: 0, isRecognized: false);
    }

    // ── 2. FIND BEST & SECOND-BEST ────────────────────────────────────────────
    double bestDist   = double.maxFinite;
    double secondDist = double.maxFinite;
    String bestLabel  = 'Unknown';

    for (final entry in knownFaces) {
      final dist = euclideanDistance(liveEmbedding, entry.value);
      debugPrint('[FaceRecognition] vs ${entry.key}: dist=$dist');
      if (dist < bestDist) {
        secondDist = bestDist;
        bestDist   = dist;
        bestLabel  = entry.key;
      } else if (dist < secondDist) {
        secondDist = dist;
      }
    }

    // ── 3. SINGLE-USER GUARD ──────────────────────────────────────────────────
    if (knownFaces.length == 1 && bestDist > kSingleUserHardMax) {
      debugPrint(
          '[FaceRecognition] Single-user rejection: $bestDist > $kSingleUserHardMax');
      return RecognitionResult(
        label:        'Unknown',
        distance:     bestDist,
        confidence:   0,
        isRecognized: false,
      );
    }

    // ── 4 & 5. ADAPTIVE DECISION ─────────────────────────────────────────────
    final double margin      = secondDist - bestDist;
    final bool isStrongMatch = bestDist < kStrongMatchThreshold;
    final bool isRecognized  =
        bestDist < threshold && (isStrongMatch || margin >= minMargin);

    // ── CONFIDENCE SCORE ──────────────────────────────────────────────────────
    final double confidence = isRecognized
        ? ((1.0 - (bestDist / threshold)) * 100).clamp(0.0, 100.0)
        : 0.0;

    debugPrint(
        '[FaceRecognition] best=$bestDist margin=$margin '
        'strong=$isStrongMatch confidence=${confidence.toStringAsFixed(1)}% '
        '→ recognized=$isRecognized');

    return RecognitionResult(
      label:        isRecognized ? bestLabel : 'Unknown',
      distance:     bestDist,
      confidence:   confidence,
      isRecognized: isRecognized,
    );
  }

  // ---------------------------------------------------------------------------
  // DUPLICATE CHECK
  // ---------------------------------------------------------------------------

  /// Returns the name of an existing face if [newEmbedding] is too similar,
  /// otherwise null.
  static String? checkDuplicateEmbedding(
    List<double> newEmbedding,
    List<MapEntry<String, List<double>>> existingFaces, {
    double duplicateThreshold = kDuplicateThreshold,
  }) {
    for (final entry in existingFaces) {
      final dist = euclideanDistance(newEmbedding, entry.value);
      if (dist < duplicateThreshold) {
        debugPrint(
            '[FaceRecognition] Duplicate detected: ${entry.key} (dist=$dist)');
        return entry.key;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // ENCODE / DECODE  (for DB persistence)
  // ---------------------------------------------------------------------------

  static String encode(List<double> embedding) => embedding.join(',');

  static List<double> decode(String s) =>
      s.split(',').map(double.parse).toList();

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  void dispose() {
    faceDetector.close();
    _interpreter?.close();
    _isLoaded = false;
    _instance = null;
  }
}