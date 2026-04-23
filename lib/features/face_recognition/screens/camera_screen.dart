import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/database_service.dart';
import '../../../core/utils/image_utils.dart';
import '../../../main.dart';
import '../providers/face_recognition_provider.dart';
import '../services/face_recognition_service.dart';
import '../services/liveness_service.dart';
import '../models/spoof_result.dart';

class CameraScreen extends ConsumerStatefulWidget {
  final String mode; // 'IN', 'OUT', or 'SCAN' (default)
  const CameraScreen({super.key, this.mode = 'SCAN'});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> with RouteAware {
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessingFrame = false;
  String? _cameraErrorMessage;
  DateTime _nextAvailableRecognition = DateTime.now();
  bool _isFlashing = false;
  FlashMode _flashMode = FlashMode.off;
  bool _isFlashSupported = false;
  String? _debugPath;

  // Throttle: process one frame every 400ms to avoid overwhelming low-end devices.
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  static const _processingInterval = Duration(milliseconds: 400);

  // Speculative Security Scan (To reduce perceived latency to 0)
  SpoofResult? _speculativeResult;
  bool _isSpeculating = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route observer to detect when we return to this screen
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didPopNext() {
    // This is called when the top route was popped and this route is visible again
    debugPrint('[Camera] Returned to screen. Re-initializing camera in 300ms…');
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _initCamera();
    });
  }

  // ─── Camera Setup ────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    // If already initialized, dispose first to avoid hardware locks
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraErrorMessage = 'No cameras found on this device.');
        return;
      }

      // Initialize debug path for AI snapshot (using External Cache for easy adb pull)
      final cacheDirs = await getExternalCacheDirectories();
      if (cacheDirs != null && cacheDirs.isNotEmpty) {
        _debugPath = p.join(cacheDirs.first.path, 'debug_ai_frame.jpg');
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

      // Reset AI result state for fresh session
      ref.read(spoofResultProvider.notifier).set(null);

      // Probe for flash support (no direct getter in camera package)
      try {
        await _cameraController!.setFlashMode(FlashMode.off);
        _isFlashSupported = true;
      } catch (_) {
        _isFlashSupported = false;
      }

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

  Future<void> _toggleFlash() async {
    if (_cameraController == null || !_isFlashSupported) return;

    final newMode = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _cameraController!.setFlashMode(newMode);
      setState(() => _flashMode = newMode);
    } catch (e) {
      debugPrint('[Camera] Flash error: $e');
    }
  }

  // ─── Frame Processing Loop ───────────────────────────────────────────────

  void _onCameraFrame(CameraImage image) async {
    // 1. Check if window is visible (Fix background scanning bug)
    if (!mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;

    // 2. Cooldown check
    if (DateTime.now().isBefore(_nextAvailableRecognition)) return;

    // Only proceed once TFLite models are loaded.
    final modelAsync = ref.read(modelLoadedProvider);
    final isAIReady = modelAsync.when(
      data: (v) => v,
      loading: () => false,
      error: (err, st) => false,
    );
    if (!isAIReady) return;

    final spoofService = ref.read(spoofDetectorServiceProvider);
    final livenessService = ref.read(livenessServiceProvider);

    // --- TRACK 2: THROTTLED PATH (Liveness & Recognition) ---
    if (_isProcessingFrame) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < _processingInterval) return;

    _lastProcessed = now;
    _isProcessingFrame = true;

    try {
      // Convert CameraImage to InputImage for ML Kit
      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;

      // Step 1: Liveness check
      final livenessState = await livenessService.processFrame(inputImage);
      
      if (!mounted) return;
      ref.read(livenessStateProvider.notifier).set(livenessState);
      ref.read(currentChallengeProvider.notifier).set(livenessService.currentChallenge);

      // Auto-reset security cache if face is lost
      if (livenessState == LivenessState.waiting) {
        _speculativeResult = null;
        ref.read(spoofResultProvider.notifier).set(null);
      }

      // --- SPECULATIVE "HEAD START" SCAN ---
      // TEST MODE: Disabled speculative scanning for continuous real-time AI testing.
      /*
      if (livenessState == LivenessState.lookStraight && !_isSpeculating && _speculativeResult == null && !spoofService.isBusy) {
        ... original speculative logic ...
      }
      */

      // --- FINAL VERIFICATION GATE ---
      if (livenessState == LivenessState.passed) {
        if (!spoofService.isBusy) {
             SpoofResult finalResult = await spoofService.detectSpoof(
               image, 
               debugPath: _debugPath, 
               cropRect: livenessService.lastFaceRect,
               sensorOrientation: _cameraController!.description.sensorOrientation,
             );
             
             if (mounted) ref.read(spoofResultProvider.notifier).set(finalResult);

             if (finalResult.isReal) {
               // Security Passed -> Proceed to recognition
               _proceedToRecognition(image);
             } else {
               // Spoof detected -> Reset liveness to force a new check
               livenessService.setSpoofDetected();
               ref.read(livenessStateProvider.notifier).set(LivenessState.spoofDetected);
             }
        }
        return;
      }

      // Removed redundant state record
    } catch (e) {
      debugPrint('[Camera] Frame error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _proceedToRecognition(CameraImage image) async {
    final livenessService = ref.read(livenessServiceProvider);
    final faceService = ref.read(faceRecognitionServiceProvider);
    
    final preprocessed = await compute(FaceRecognitionService.preprocessCameraImage, image);
    if (preprocessed == null) return;

    final liveEmbedding = faceService.generateEmbedding(preprocessed);
    if (liveEmbedding == null) return;

    final employees = await DatabaseService.instance.getAllEmployees();
    if (employees.isEmpty) {
      _showUnrecognizedBanner('No employees registered.');
      livenessService.reset();
      return;
    }

    final knownFaces = employees.map((e) => MapEntry(e.name, e.facialEmbedding)).toList();
    final result = await compute((data) {
      return FaceRecognitionService.findBestMatch(data.key, data.value);
    }, MapEntry(liveEmbedding, knownFaces));

    livenessService.reset();
    _speculativeResult = null;

    if (result.isRecognized) {
      final recognizedEmployee = employees.firstWhere((e) => e.name == result.label);
      ref.read(recognizedEmployeeProvider.notifier).set(recognizedEmployee.name);
      
      await _cameraController?.stopImageStream();
      _nextAvailableRecognition = DateTime.now().add(const Duration(seconds: 5));

      if (mounted) {
        final actionToPass = widget.mode == 'SCAN' ? null : widget.mode;
        await Navigator.of(context).pushNamed('/action', arguments: {
          'employee': recognizedEmployee,
          'action': actionToPass,
        });
        
        if (mounted && _cameraController != null) {
          _cameraController!.startImageStream(_onCameraFrame);
          ref.read(livenessStateProvider.notifier).set(LivenessState.waiting);
        }
      }
    } else {
      _speculativeResult = null;
      ref.read(spoofResultProvider.notifier).set(null);
      ref.read(recognizedEmployeeProvider.notifier).set(null);
      _showUnrecognizedBanner('Face not recognized.');
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

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
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
          
          // ── Active Illumination Overlay ───────────────────────────
          if (_isFlashing)
            Positioned.fill(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: _isFlashing ? 0.4 : 0.0,
                child: Container(color: Colors.cyanAccent),
              ),
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

          // ── Top Navigation Bar ────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 10),
                            SizedBox(width: 4),
                            Text(
                              'LIVE FEED',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                        const Text(
                          'ALAMS SECURITY',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.teal.withAlpha(50),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.tealAccent.withAlpha(100)),
                          ),
                          child: const Text(
                            'SECURE AREA • AI ACTIVE',
                            style: TextStyle(color: Colors.tealAccent, fontSize: 8, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    if (_isFlashSupported)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: IconButton.filledTonal(
                          icon: Icon(_flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_off),
                          onPressed: _toggleFlash,
                          color: _flashMode == FlashMode.torch ? Colors.yellowAccent : Colors.white70,
                        ),
                      ),
                    IconButton.filledTonal(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
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
            child: _LivenessStatusBadge(state: livenessState, isSpeculating: _isSpeculating),
          ),

          // ── Real-Time Authenticity Label ──────────────────────────
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: _AuthenticityLabel(),
          ),

          // ── AI X-Ray Preview (Real-time facial crop) ────────────────
          Positioned(
            top: 110,
            left: 20,
            child: Consumer(
              builder: (context, ref, _) {
                final result = ref.watch(spoofResultProvider);
                if (result?.faceCrop == null) return const SizedBox.shrink();
                return Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.tealAccent.withAlpha(150), width: 1.5),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.black,
                    boxShadow: [
                      BoxShadow(color: Colors.black.withAlpha(100), blurRadius: 8),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      children: [
                        Image.memory(
                          result!.faceCrop!,
                          width: 90,
                          height: 90,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                        Positioned(
                          top: 4, left: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: const Text(
                              'AI X-RAY',
                              style: TextStyle(color: Colors.tealAccent, fontSize: 6, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Bottom Logo & Hidden Admin Link ───────────────────────
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: Column(
                children: [
                  Image.network(
                    'https://cdn-icons-png.flaticon.com/512/2932/2932915.png', // Replace with local logo if available
                    width: 40,
                    height: 40,
                    color: Colors.white24,
                    errorBuilder: (ctx, e, st) => const Icon(Icons.shield_outlined, color: Colors.white24),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'SCAN TO LOG ATTENDANCE',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ],
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
      LivenessState.spoofDetected => Colors.redAccent,
      LivenessState.performingChallenge => Colors.white,
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

class _LivenessStatusBadge extends ConsumerWidget {
  final LivenessState state;
  final bool isSpeculating;
  const _LivenessStatusBadge({required this.state, required this.isSpeculating});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final challenge = ref.watch(currentChallengeProvider);

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
      LivenessState.performingChallenge => _getChallengeData(challenge),
      LivenessState.passed => (
          'Identity verified ✓',
          Icons.check_circle_outline,
          Colors.tealAccent
        ),
      LivenessState.failed => (
          'Liveness failed – try again',
          Icons.warning_amber_rounded,
          Colors.redAccent
        ),
      LivenessState.spoofDetected => (
          'SPOOF DETECTED! Use a real face.',
          Icons.gpp_bad_rounded,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSpeculating && state == LivenessState.passed)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.tealAccent),
                  )
                else
                  Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(
                  state == LivenessState.passed && isSpeculating ? 'HIGH-SECURITY AI SCAN' : text,
                  style: TextStyle(
                      color: color, fontSize: 15, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            if (state == LivenessState.passed && isSpeculating) ...[
              const SizedBox(height: 12),
              const Text(
                'Identity Verified. Please hold perfectly still for 3D security check...',
                style: TextStyle(color: Colors.white70, fontSize: 11),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: const SizedBox(
                  width: 180,
                  height: 4,
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.white10,
                    color: Colors.tealAccent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (String, IconData, Color) _getChallengeData(LivenessChallenge? challenge) {
    return switch (challenge) {
      LivenessChallenge.blink => (
          'Step: Blink naturally',
          Icons.visibility,
          Colors.tealAccent
        ),
      LivenessChallenge.mouthOpen => (
          'Step: Open your mouth slightly',
          Icons.sentiment_satisfied_alt_outlined,
          Colors.tealAccent
        ),
      LivenessChallenge.turnLeft => (
          'Step: Turn your head LEFT',
          Icons.arrow_back,
          Colors.tealAccent
        ),
      LivenessChallenge.turnRight => (
          'Step: Turn your head RIGHT',
          Icons.arrow_forward,
          Colors.tealAccent
        ),
      LivenessChallenge.smile => (
          'Step: Smile for the camera',
          Icons.emoji_emotions_outlined,
          Colors.tealAccent
        ),
      null => ('Wait...', Icons.hourglass_empty, Colors.white60),
    };
  }
}

// ─── Real-Time Authenticity Label ──────────────────────────────────────────

class _AuthenticityLabel extends ConsumerWidget {
  const _AuthenticityLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spoofResult = ref.watch(spoofResultProvider);
    final livenessState = ref.watch(livenessStateProvider);
    
    // UI GATING: Only show the security label if a face is actually being scanned.
    // This prevents "AUTHENTIC FACE" labels on empty rooms/backgrounds.
    if (spoofResult == null || livenessState == LivenessState.waiting) {
      return const SizedBox.shrink();
    }

    final isReal = spoofResult.isReal;
    final color = isReal ? Colors.greenAccent : Colors.redAccent;
    final text = isReal ? 'AUTHENTIC FACE' : 'SPOOF DETECTED';
    final icon = isReal ? Icons.verified_user_rounded : Icons.gpp_bad_rounded;

    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withAlpha(150), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
