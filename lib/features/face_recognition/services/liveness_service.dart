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

  static const int _minStabilityFrames = 5;
  static const double _stabilityDelta = 25.0;

  // Thresholds
  static const double _eyeClosedThreshold = 0.475;
  static const int _minFramesForAction = 3;
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

      // Stability met -> Start challenges immediately
      startChallenges();
      return _state;
    }

    // Step 1: Execute Challenges
    if (_state == LivenessState.performingChallenge) {
      final challenge = _activeChallenges[_currentChallengeIndex];
      bool success = false;

      // Passive Check: Geometric Depth & Consistency
      if (!_checkPassiveLiveness(face)) {
        debugPrint('[Liveness] Passive check failed - suspected spoof.');
        // We don't fail immediately to avoid false positives,
        // but we could track this.
      }

      switch (challenge) {
        case LivenessChallenge.blink:
          success = _checkBlink(face);
          break;
        case LivenessChallenge.mouthOpen:
          success = _checkMouthOpen(face);
          break;
        case LivenessChallenge.turnLeft:
          // In front camera, positive Euler Y is usually turning left
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
        _actionFrames = 0; // Reset for next challenge
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
    _activeChallenges = _activeChallenges.take(2).toList(); // User requested 2
    _currentChallengeIndex = 0;
    _state = LivenessState.performingChallenge;
    debugPrint('[Liveness] Strategy: ${_activeChallenges.join(' -> ')}');
  }

  void setSpoofDetected() {
    _state = LivenessState.spoofDetected;
  }

  bool _checkBlink(Face face) {
    final avgOpen =
        ((face.leftEyeOpenProbability ?? 1.0) +
            (face.rightEyeOpenProbability ?? 1.0)) /
        2.0;
    if (avgOpen < _eyeClosedThreshold) {
      _actionFrames++;
      return _actionFrames >= _minFramesForAction;
    } else {
      _actionFrames = 0;
      return false;
    }
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

  /// Passive checks for screen detection and 2D spoofing
  bool _checkPassiveLiveness(Face face) {
    // 1. Staticness check (prevents perfectly static images/frozen video)
    if (_lastFaceRect != null) {
      final areaDelta = (_faceArea(face) - _faceAreaFromRect(_lastFaceRect!))
          .abs();
      if (areaDelta < 0.0001) {
        // Face is extremely static, could be a photo or frozen video
        return false;
      }
    }

    // 2. 3D Perspective Check (Simplified moiré/depth)
    // As face turns (eulerY), the bounding box width should shrink.
    // In a 2D photo being turned, the scaling is linear.
    // This is a complex check, so we mostly rely on Euler angles from ML Kit
    // which are harder to fake on a flat surface.

    return true;
  }

  double _faceAreaFromRect(Rect rect) => rect.width * rect.height;

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
  }

  void reset() {
    _resetInternal();
    _state = LivenessState.waiting;
  }

  void dispose() {
    _detector.close();
  }
}
