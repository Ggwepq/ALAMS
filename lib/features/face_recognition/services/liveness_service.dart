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

  /// Process a single [InputImage] frame. Returns updated [LivenessState].
  Future<LivenessState> processFrame(InputImage inputImage) async {
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) {
      _state = LivenessState.waiting;
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

    // Transition: open -> closed = blink start
    if (!_eyeWasClosed && eyesCurrentlyClosed) {
      _eyeWasClosed = true;
    }
    // Transition: closed -> open = blink complete
    if (_eyeWasClosed && eyesCurrentlyOpen) {
      _eyeWasClosed = false;
      _blinkCount++;
      debugPrint('[Liveness] Blink detected. Count: $_blinkCount');
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
