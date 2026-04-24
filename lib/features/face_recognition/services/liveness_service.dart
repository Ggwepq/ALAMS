import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// State of the liveness check.
enum LivenessState {
  waiting, // Waiting for face to appear
  lookStraight, // Step 0: Face stability check
  performingChallenge, // Current active randomized challenge
  passed, // Liveness confirmed
  failed, // Multiple failed attempts detected
  spoofDetected, // Explicit AI detection of photo/screen
}

/// Types of liveness challenges
enum LivenessChallenge { blink, mouthOpen, turnLeft, turnRight, smile }

class LivenessService {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true, // eye-open, smiling
      enableLandmarks: true,
      enableContours: true,
      enableTracking: true,
      minFaceSize: 0.15,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  LivenessState _state = LivenessState.waiting;

  // Challenge Management
  final List<LivenessChallenge> _challengePool = [
    LivenessChallenge.blink,
    LivenessChallenge.mouthOpen,
    LivenessChallenge.turnLeft,
    LivenessChallenge.turnRight,
    LivenessChallenge.smile,
  ];

  List<LivenessChallenge> _activeChallenges = [];
  int _currentChallengeIndex = 0;

  // Internal counters/state
  int _actionFrames = 0;
  int _stabilityFrames = 0;
  Rect? _lastFaceRect;
  
  // Blink State Machine: Open -> Closed -> Open
  bool _eyesClosedDetected = false;

  static const int _minStabilityFrames = 5;
  static const double _stabilityDelta = 25.0;

  // Thresholds
  static const double _eyeClosedThreshold = 0.35; // Stricter for "true" closed
  static const double _eyeOpenThreshold = 0.65;   // Higher for "true" open
  static const int _minFramesForAction = 2;       // For mouth/smile
  static const double _mouthOpenThreshold = 0.08;
  static const double _smileThreshold = 0.70;
  static const double _turnAngleThreshold = 25.0; // Degrees

  LivenessState get state => _state;
  Rect? get lastFaceRect => _lastFaceRect;
  LivenessChallenge? get currentChallenge =>
      (_state == LivenessState.performingChallenge &&
          _activeChallenges.isNotEmpty)
      ? _activeChallenges[_currentChallengeIndex]
      : null;

  /// Process a single [InputImage] frame.
  Future<LivenessState> processFrame(InputImage inputImage) async {
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) {
      _resetInternal();
      _state = LivenessState.waiting;
      return _state;
    }

    // Get Largest Face
    final face = faces.reduce((a, b) => _faceArea(a) > _faceArea(b) ? a : b);

    // Step 0: Stability & Selection
    if (_state == LivenessState.waiting ||
        _state == LivenessState.lookStraight) {
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

      // Stability met - Stay in lookStraight until externally triggered (after Anti-Spoofing check)
      _state = LivenessState.lookStraight;
      return _state;
    }

    // Step 1: Execute Challenges
    if (_state == LivenessState.performingChallenge) {
      final challenge = _activeChallenges[_currentChallengeIndex];
      bool success = false;

      switch (challenge) {
        case LivenessChallenge.blink:
          success = _checkBlink(face);
          break;
        case LivenessChallenge.mouthOpen:
          success = _checkMouthOpen(face);
          break;
        case LivenessChallenge.turnLeft:
          success = (face.headEulerAngleY ?? 0.0) > _turnAngleThreshold;
          break;
        case LivenessChallenge.turnRight:
          success = (face.headEulerAngleY ?? 0.0) < -_turnAngleThreshold;
          break;
        case LivenessChallenge.smile:
          success = (face.smilingProbability ?? 0.0) > _smileThreshold;
          break;
      }

      if (success) {
        _actionFrames = 0; 
        _blinkStateReset();
        _currentChallengeIndex++;
        debugPrint('[Liveness] Challenge completed: $challenge');

        if (_currentChallengeIndex >= _activeChallenges.length) {
          _state = LivenessState.passed;
        }
      }
    }

    return _state;
  }

  void startChallenges() {
    final random = math.Random();
    _activeChallenges = List.from(_challengePool)..shuffle(random);
    _activeChallenges = _activeChallenges.take(2).toList(); 
    _currentChallengeIndex = 0;
    _state = LivenessState.performingChallenge;
    _blinkStateReset();
    debugPrint('[Liveness] Strategy: ${_activeChallenges.join(' -> ')}');
  }

  void _blinkStateReset() {
    _eyesClosedDetected = false;
  }

  void setSpoofDetected() {
    _state = LivenessState.spoofDetected;
  }

  /// Improved Blink State Machine: Open -> Closed -> Open
  bool _checkBlink(Face face) {
    final probL = face.leftEyeOpenProbability ?? 1.0;
    final probR = face.rightEyeOpenProbability ?? 1.0;
    final avgOpen = (probL + probR) / 2.0;

    if (!_eyesClosedDetected && avgOpen < _eyeClosedThreshold) {
      _eyesClosedDetected = true;
      debugPrint('[Liveness] Blink: Eyes SUB-THRESHOLD detected');
      return false;
    }

    if (_eyesClosedDetected && avgOpen > _eyeOpenThreshold) {
      debugPrint('[Liveness] Blink: Eyes RE-OPENED - PASS');
      return true;
    }

    return false;
  }

  bool _checkMouthOpen(Face face) {
    final upperLip = face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerLip = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upperLip == null ||
        lowerLip == null ||
        upperLip.isEmpty ||
        lowerLip.isEmpty)
      return false;

    final gap =
        (lowerLip[lowerLip.length ~/ 2].y - upperLip[upperLip.length ~/ 2].y)
            .abs();
    final isOpened = (gap / face.boundingBox.height) > _mouthOpenThreshold;

    if (isOpened) {
      _actionFrames++;
      return _actionFrames >= _minFramesForAction;
    } else {
      _actionFrames = 0;
      return false;
    }
  }

  double _faceArea(Face face) {
    final bb = face.boundingBox;
    return bb.width * bb.height;
  }

  void _resetInternal() {
    _actionFrames = 0;
    _stabilityFrames = 0;
    _lastFaceRect = null;
    _activeChallenges = [];
    _currentChallengeIndex = 0;
    _blinkStateReset();
  }

  void reset() {
    _resetInternal();
    _state = LivenessState.waiting;
  }

  void dispose() {
    _detector.close();
  }
}
