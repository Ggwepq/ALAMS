import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// State of the liveness check.
enum LivenessState {
  waiting,        // Waiting for face to appear
  lookStraight,   // Instruction: face the camera straight
  blink,          // Instruction: blink
  passed,         // Liveness confirmed
  failed,         // Multiple failed attempts detected
}

class LivenessService {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,    // enables eye-open probability
      enableLandmarks: true,         // enables facial landmarks
      enableContours: false,
      enableTracking: true,          // track same face across frames
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  LivenessState _state = LivenessState.waiting;
  int _blinkCount = 0;
  bool _eyeWasClosed = false;

  // Thresholds
  static const double _eyeOpenThreshold = 0.7;   // above this = open
  static const double _eyeClosedThreshold = 0.3; // below this = closed

  LivenessState get state => _state;

  int _closedFrames = 0;
  static const int _minClosedFrames = 2; // Reduced from 3 to be more responsive but still secure

  /// Process a single [InputImage] frame. Returns updated [LivenessState].
  Future<LivenessState> processFrame(InputImage inputImage) async {
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) {
      _state = LivenessState.waiting;
      _eyeWasClosed = false;
      _closedFrames = 0;
      return _state;
    }

    // Use the largest / most prominent face
    final face = faces.reduce((a, b) => _faceArea(a) > _faceArea(b) ? a : b);

    // Step 1: Require roughly frontal pose
    final eulerY = face.headEulerAngleY ?? 0;
    final eulerZ = face.headEulerAngleZ ?? 0;
    if (eulerY.abs() > 20 || eulerZ.abs() > 20) {
      _state = LivenessState.lookStraight;
      return _state;
    }

    // Step 2: Blink detection
    final leftOpen = face.leftEyeOpenProbability ?? 1.0;
    final rightOpen = face.rightEyeOpenProbability ?? 1.0;
    final avgOpen = (leftOpen + rightOpen) / 2;

    final bool eyesCurrentlyClosed = avgOpen < _eyeClosedThreshold;
    final bool eyesCurrentlyOpen = avgOpen > _eyeOpenThreshold;

    // Transition Logic:
    // 1. If eyes are closed, start/continue counting closed frames.
    if (eyesCurrentlyClosed) {
      _closedFrames++;
      _eyeWasClosed = true;
    } 
    // 2. If eyes were closed and are now open, check if it was a valid blink.
    else if (_eyeWasClosed && eyesCurrentlyOpen) {
      if (_closedFrames >= _minClosedFrames) {
        _blinkCount++;
        debugPrint('[Liveness] Valid blink detected. Total: $_blinkCount');
      }
      _eyeWasClosed = false;
      _closedFrames = 0;
    }
    // 3. Reset if eyes are just open and we haven't started a blink.
    else if (eyesCurrentlyOpen) {
      _eyeWasClosed = false;
      _closedFrames = 0;
    }

    if (_blinkCount >= 1) {
      _state = LivenessState.passed;
    } else {
      _state = LivenessState.blink;
    }

    return _state;
  }

  double _faceArea(Face face) {
    final bb = face.boundingBox;
    return bb.width * bb.height;
  }

  /// Reset liveness state for a new recognition attempt.
  void reset() {
    _state = LivenessState.waiting;
    _blinkCount = 0;
    _eyeWasClosed = false;
  }

  void dispose() {
    _detector.close();
  }
}
