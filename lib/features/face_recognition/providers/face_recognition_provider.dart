import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/face_recognition_service.dart';
import '../services/liveness_service.dart';

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

/// Tracks the current liveness state across frames.
final livenessStateProvider =
    NotifierProvider<_LivenessNotifier, LivenessState>(
  _LivenessNotifier.new,
);

class _LivenessNotifier extends Notifier<LivenessState> {
  @override
  LivenessState build() => LivenessState.waiting;
  void set(LivenessState state) => this.state = state;
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

/// Whether the model is ready to run inference.
final modelLoadedProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(faceRecognitionServiceProvider);
  await service.loadModel();
  return service.isLoaded;
});
