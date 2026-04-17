import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../../core/database/database_service.dart';
import '../../../core/utils/image_utils.dart';
import '../providers/face_recognition_provider.dart';
import '../services/face_recognition_service.dart';
import '../services/liveness_service.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessingFrame = false;
  String? _cameraErrorMessage;
  DateTime _nextAvailableRecognition = DateTime.now();

  // Throttle: process one frame every 400ms to avoid overwhelming low-end devices.
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  static const _processingInterval = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  // ─── Camera Setup ────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraErrorMessage = 'No cameras found on this device.');
        return;
      }

      final frontCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      if (!mounted) return;

      setState(() {
        _isCameraInitialized = true;
        _cameraErrorMessage = null;
      });

      // Start streaming frames after model is loaded.
      _cameraController!.startImageStream(_onCameraFrame);
    } catch (e) {
      debugPrint('[Camera] Init error: $e');
      if (mounted) {
        setState(() {
          if (e is CameraException && e.code == 'CameraAccessDenied') {
            _cameraErrorMessage = 'Camera permission was denied. Please enable it in settings.';
          } else {
            _cameraErrorMessage = 'Failed to initialize camera: $e';
          }
        });
      }
    }
  }

  // ─── Frame Processing Loop ───────────────────────────────────────────────

  void _onCameraFrame(CameraImage image) async {
    // 1. Check if window is visible (Fix background scanning bug)
    if (!mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;

    // 2. Cooldown check
    if (DateTime.now().isBefore(_nextAvailableRecognition)) return;

    if (_isProcessingFrame) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < _processingInterval) return;
    _lastProcessed = now;

    // Only proceed once TFLite model is loaded.
    final modelAsync = ref.read(modelLoadedProvider);
    final modelLoaded = modelAsync.when(
      data: (v) => v,
      loading: () => false,
      error: (err, st) => false,
    );
    if (!modelLoaded) return;

    _isProcessingFrame = true;

    try {
      // Convert CameraImage to InputImage for ML Kit
      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;

      // Step 1: Liveness check
      final livenessService = ref.read(livenessServiceProvider);
      final livenessState = await livenessService.processFrame(inputImage);
      ref.read(livenessStateProvider.notifier).set(livenessState);

      // Only proceed to recognition after liveness passes
      if (livenessState != LivenessState.passed) return;

      // Step 2: Preprocessed Image (In Isolate to fix lag)
      final faceService = ref.read(faceRecognitionServiceProvider);
      final preprocessed = await compute(FaceRecognitionService.preprocessCameraImage, image);
      if (preprocessed == null) {
        livenessService.reset(); // Error, reset for safety
        return;
      }

      // Step 3: Generate embedding (TFLite Inference usually runs on native worker)
      final liveEmbedding = faceService.generateEmbedding(preprocessed);
      if (liveEmbedding == null) {
        livenessService.reset();
        return;
      }

      // Step 4: Match against DB (In Isolate if list is large)
      final employees = await DatabaseService.instance.getAllEmployees();
      if (employees.isEmpty) {
        _showUnrecognizedBanner('No employees registered.');
        livenessService.reset();
        return;
      }

      final knownFaces = employees
          .map((e) => MapEntry(e.name, e.facialEmbedding))
          .toList();

      // For extra smoothness, match in isolate too
      final result = await compute((data) {
        return FaceRecognitionService.findBestMatch(data.key, data.value);
      }, MapEntry(liveEmbedding, knownFaces));

      // Always reset liveness for the NEXT frame/attempt
      livenessService.reset();

      if (result.isRecognized) {
        ref.read(recognizedEmployeeProvider.notifier).set(result.label);
        
        // Pause stream and set navigation cooldown
        await _cameraController?.stopImageStream();
        _nextAvailableRecognition = DateTime.now().add(const Duration(seconds: 5));

        if (mounted) {
          await Navigator.of(context).pushNamed('/action', arguments: result.label);
          
          // RESTART stream when coming back
          if (mounted && _cameraController != null) {
            _cameraController!.startImageStream(_onCameraFrame);
            ref.read(livenessStateProvider.notifier).set(LivenessState.waiting);
          }
        }
      } else {
        ref.read(recognizedEmployeeProvider.notifier).set(null);
        _showUnrecognizedBanner('Face not recognized.');
      }
    } catch (e) {
      debugPrint('[Camera] Frame error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _showUnrecognizedBanner(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.redAccent.withAlpha(200),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 180, left: 40, right: 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Build ML Kit [InputImage] from raw [CameraImage].
  InputImage? _buildInputImage(CameraImage image) {
    if (_cameraController == null) return null;
    return buildInputImageForMLKit(
      image: image,
      camera: _cameraController!.description,
    );
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final modelAsync = ref.watch(modelLoadedProvider);
    final livenessState = ref.watch(livenessStateProvider);

    // 1. Error state (Permission denied or hardware failure)
    if (_cameraErrorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_photography_outlined, color: Colors.redAccent, size: 64),
                const SizedBox(height: 24),
                Text(
                  _cameraErrorMessage!,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _initCamera,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 2. Loading state while camera initializes
    if (!_isCameraInitialized || _cameraController == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.teal),
              SizedBox(height: 16),
              Text('Starting camera…', style: TextStyle(color: Colors.white60)),
            ],
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Live Camera Feed ──────────────────────────────────────
          Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(_cameraController!)),
          ),

          // ── Dark gradient at bottom ───────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 260,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),

          // ── Oval face guide overlay ───────────────────────────────
          Center(
            child: CustomPaint(
              size: Size(size.width, size.height),
              painter: _FaceOvalPainter(livenessState: livenessState),
            ),
          ),

          // ── Top Navigation Bar (Reports & Registration) ──────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Reports Button
                    IconButton(
                      icon: const Icon(Icons.bar_chart_rounded, color: Colors.white, size: 30),
                      onPressed: () => Navigator.of(context).pushNamed('/reports'),
                      tooltip: 'Attendance Reports',
                    ),
                    // Add Employee Button
                    IconButton(
                      icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white, size: 30),
                      onPressed: () => Navigator.of(context).pushNamed('/register'),
                      tooltip: 'Register New Employee',
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Liveness Status Label ─────────────────────────────────
          Positioned(
            bottom: 110,
            left: 24,
            right: 24,
            child: _LivenessStatusBadge(state: livenessState),
          ),

          // ── Model loading indicator ───────────────────────────────
          if (modelAsync.isLoading)
            Positioned(
              top: 56,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child:
                            CircularProgressIndicator(strokeWidth: 2, color: Colors.tealAccent),
                      ),
                      const SizedBox(width: 8),
                      const Text('Loading model…',
                          style: TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Face Oval Painter ──────────────────────────────────────────────────────

class _FaceOvalPainter extends CustomPainter {
  final LivenessState livenessState;
  _FaceOvalPainter({required this.livenessState});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.42;
    final ovalW = size.width * 0.6;
    final ovalH = ovalW * 1.35;

    final Color strokeColor = switch (livenessState) {
      LivenessState.passed => Colors.tealAccent,
      LivenessState.lookStraight => Colors.orangeAccent,
      LivenessState.blink => Colors.white,
      _ => Colors.white38,
    };

    final paint = Paint()
      ..color = strokeColor
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx, cy), width: ovalW, height: ovalH),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _FaceOvalPainter old) =>
      old.livenessState != livenessState;
}

// ─── Liveness Status Badge ──────────────────────────────────────────────────

class _LivenessStatusBadge extends StatelessWidget {
  final LivenessState state;
  const _LivenessStatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final (text, icon, color) = switch (state) {
      LivenessState.waiting => (
          'Position your face in the oval',
          Icons.face,
          Colors.white70
        ),
      LivenessState.lookStraight => (
          'Look straight at the camera',
          Icons.center_focus_strong,
          Colors.orange
        ),
      LivenessState.blink => (
          'Now blink naturally',
          Icons.visibility,
          Colors.tealAccent
        ),
      LivenessState.passed => (
          'Liveness confirmed ✓',
          Icons.check_circle_outline,
          Colors.tealAccent
        ),
      LivenessState.failed => (
          'Liveness failed – try again',
          Icons.warning_amber_rounded,
          Colors.redAccent
        ),
    };

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(178),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withAlpha(100)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                    color: color, fontSize: 15, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
