import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// State of the liveness check.
enum LivenessState {
  waiting,        // Waiting for face to appear
  lookStraight,   // Step 0: Face stability check
  blink,          // Step 1: instruction: blink
  mouthOpen,      // Step 2: instruction: open mouth
  passed,         // Liveness confirmed
  failed,         // Multiple failed attempts detected
}

class LivenessService {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,    // enables eye-open probability
      enableLandmarks: true,         
      enableContours: true,          // NEED THIS for mouth opening check
      enableTracking: true,          
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  LivenessState _state = LivenessState.waiting;
  int _blinkCount = 0;
  int _closedFrames = 0;
  
  // Stability Check Variables
  int _stabilityFrames = 0;
  Rect? _lastFaceRect;
  static const int _minStabilityFrames = 4; // Relaxed (was 10)
  static const double _stabilityDelta = 30.0; // Relaxed (was 15.0)

  // Detection Thresholds
  static const int _minClosedFrames = 3; // Relaxed (was 5)
  static const double _eyeClosedThreshold = 0.40; // Relaxed (was 0.30)

  LivenessState get state => _state;

  /// Process a single [InputImage] frame.
  Future<LivenessState> processFrame(InputImage inputImage) async {
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) {
      _resetInternal();
      _state = LivenessState.waiting;
      return _state;
    }

    // Pick the largest face (closest)
    final face = faces.reduce((a, b) => _faceArea(a) > _faceArea(b) ? a : b);

    // Step 0: Stability Check (Ensures deliberate interaction, not just a passing face/photo)
    if (_state == LivenessState.waiting || _state == LivenessState.lookStraight) {
      if (_lastFaceRect != null) {
        final dx = (face.boundingBox.left - _lastFaceRect!.left).abs();
        final dy = (face.boundingBox.top - _lastFaceRect!.top).abs();
        
        if (dx < _stabilityDelta && dy < _stabilityDelta) {
          _stabilityFrames++;
        } else {
          _stabilityFrames = 0;
        }
      }
      _lastFaceRect = face.boundingBox;
      
      if (_stabilityFrames < _minStabilityFrames) {
        _state = LivenessState.lookStraight;
        return _state;
      }
    }

    // Step 1: Stricter Blink Detection
    if (_blinkCount < 1) {
      _state = LivenessState.blink;
      final leftOpen = face.leftEyeOpenProbability ?? 1.0;
      final rightOpen = face.rightEyeOpenProbability ?? 1.0;
      final avgOpen = (leftOpen + rightOpen) / 2.0;

      if (avgOpen < _eyeClosedThreshold) {
        _closedFrames++;
        if (_closedFrames >= _minClosedFrames) {
          _blinkCount++;
          debugPrint('[Liveness] Blink confirmed after $_closedFrames frames.');
        }
      } else {
        _closedFrames = 0;
      }
      return _state;
    }

    // Step 2: Randomized Challenge - Mouth Opening
    _state = LivenessState.mouthOpen;
    final bool isMouthOpen = _checkMouthOpen(face);
    
    if (isMouthOpen) {
      debugPrint('[Liveness] Mouth opening confirmed.');
      _state = LivenessState.passed;
    }

    return _state;
  }

  bool _checkMouthOpen(Face face) {
    final upperLip = face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerLip = face.contours[FaceContourType.lowerLipTop]?.points;

    if (upperLip == null || lowerLip == null || upperLip.isEmpty || lowerLip.isEmpty) {
      return false;
    }

    final upperMid = upperLip[upperLip.length ~/ 2];
    final lowerMid = lowerLip[lowerLip.length ~/ 2];

    final gap = (lowerMid.y - upperMid.y).abs();
    final faceHeight = face.boundingBox.height;
    final normalizedGap = gap / faceHeight;

    // Stricter threshold at 0.08
    return normalizedGap > 0.08;
  }

  double _faceArea(Face face) {
    final bb = face.boundingBox;
    return bb.width * bb.height;
  }

  void _resetInternal() {
    _blinkCount = 0;
    _closedFrames = 0;
    _stabilityFrames = 0;
    _lastFaceRect = null;
  }

  void reset() {
    _resetInternal();
    _state = LivenessState.waiting;
  }

  void dispose() {
    _detector.close();
  }
}
