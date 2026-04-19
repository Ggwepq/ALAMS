import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/face_recognition_service.dart';
import '../services/liveness_service.dart';
import '../services/spoof_detector_service.dart';
import '../services/spoof_worker.dart';

/// Provider for the singleton FaceRecognitionService.
final faceRecognitionServiceProvider = Provider<FaceRecognitionService>((ref) {
  final service = FaceRecognitionService.instance;
  ref.onDispose(service.dispose);
  return service;
});

/// Provider for the LivenessService.
final livenessServiceProvider = Provider<LivenessService>((ref) {
  final service = LivenessService();
  ref.onDispose(service.dispose);
  return service;
});

/// Provider for the singleton SpoofDetectorService.
final spoofDetectorServiceProvider = Provider<SpoofDetectorService>((ref) {
  final service = SpoofDetectorService.instance;
  ref.onDispose(service.dispose);
  return service;
});

final livenessStateProvider =
    NotifierProvider<_LivenessNotifier, LivenessState>(
  _LivenessNotifier.new,
);

class _LivenessNotifier extends Notifier<LivenessState> {
  @override
  LivenessState build() => LivenessState.waiting;
  void set(LivenessState state) => this.state = state;
}

final currentChallengeProvider =
    NotifierProvider<_ChallengeNotifier, LivenessChallenge?>(
  _ChallengeNotifier.new,
);

class _ChallengeNotifier extends Notifier<LivenessChallenge?> {
  @override
  LivenessChallenge? build() => null;
  void set(LivenessChallenge? value) => state = value;
}

/// Holds the currently recognized employee name after a successful match.
final recognizedEmployeeProvider =
    NotifierProvider<_RecognizedEmployeeNotifier, String?>(
  _RecognizedEmployeeNotifier.new,
);

class _RecognizedEmployeeNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? name) => state = name;
}

/// Tracks the latest AI spoof detection result for real-time UI labeling.
final spoofResultProvider =
    NotifierProvider<_SpoofResultNotifier, SpoofWorkerResult?>(
  _SpoofResultNotifier.new,
);

class _SpoofResultNotifier extends Notifier<SpoofWorkerResult?> {
  @override
  SpoofWorkerResult? build() => null;
  void set(SpoofWorkerResult? value) => state = value;
}

/// Whether all AI models are ready to run inference.
final modelLoadedProvider = FutureProvider<bool>((ref) async {
  final faceService = ref.watch(faceRecognitionServiceProvider);
  final spoofService = ref.read(spoofDetectorServiceProvider);
  
  await faceService.loadModel();
  await spoofService.loadModel();
  
  return faceService.isLoaded && spoofService.isLoaded;
});
