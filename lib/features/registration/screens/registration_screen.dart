import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';
import '../../../core/utils/image_utils.dart';
import '../../face_recognition/services/face_recognition_service.dart';

// State for the registration flow
enum RegistrationStep { enterName, scanFace, processing, success, error }

class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({super.key});

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  // ── Name entry
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // ── Camera
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _isProcessingFrame = false;

  // ── Face samples captured so far (we average 5 for a stable embedding)
  final List<List<double>> _capturedEmbeddings = [];
  static const int _requiredSamples = 5;

  // ── ML Kit face detector (just to confirm a face is present in frame)
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: false,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.2,
    ),
  );

  RegistrationStep _step = RegistrationStep.enterName;
  String _statusMessage = 'Position face in frame. Hold still…';
  String _errorMessage = '';

  @override
  void dispose() {
    _nameController.dispose();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  // ─── Camera Init ─────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    setState(() => _isCameraReady = true);

    // Ensure model loaded
    await FaceRecognitionService.instance.loadModel();
    _cameraController!.startImageStream(_onFrame);
  }

  // ─── Frame Processing ─────────────────────────────────────────────────────

  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  void _onFrame(CameraImage image) async {
    if (_isProcessingFrame || _step != RegistrationStep.scanFace) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < const Duration(milliseconds: 500)) return;
    _lastProcessed = now;

    _isProcessingFrame = true;

    try {
      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      if (faces.isEmpty) {
        if (mounted) setState(() => _statusMessage = 'No face detected. Move closer.');
        return;
      }

      // Generate embedding
      final faceService = FaceRecognitionService.instance;
      final preprocessed = faceService.preprocessCameraImage(image);
      if (preprocessed == null) return;
      final embedding = faceService.generateEmbedding(preprocessed);
      if (embedding == null) return;

      _capturedEmbeddings.add(embedding);

      final count = _capturedEmbeddings.length;
      if (mounted) {
        setState(() {
          _statusMessage = 'Capturing… $count / $_requiredSamples';
        });
      }

      if (count >= _requiredSamples) {
        await _cameraController?.stopImageStream();
        _saveEmployee();
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    if (_cameraController == null) return null;
    return buildInputImageForMLKit(
      image: image,
      camera: _cameraController!.description,
    );
  }

  // ─── Save to DB ───────────────────────────────────────────────────────────

  Future<void> _saveEmployee() async {
    setState(() => _step = RegistrationStep.processing);

    try {
      // Average all captured embeddings for a stable reference
      final avgEmbedding = _averageEmbeddings(_capturedEmbeddings);
      final name = _nameController.text.trim();

      await DatabaseService.instance.insertEmployee(
        Employee(name: name, facialEmbedding: avgEmbedding),
      );

      if (mounted) {
        setState(() {
          _step = RegistrationStep.success;
          _statusMessage = '$name has been registered!';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = RegistrationStep.error;
          _errorMessage = 'Failed to save: $e';
        });
      }
    }
  }

  List<double> _averageEmbeddings(List<List<double>> embeddings) {
    final len = embeddings.first.length;
    final avg = List<double>.filled(len, 0.0);
    for (final emb in embeddings) {
      for (int i = 0; i < len; i++) {
        avg[i] += emb[i];
      }
    }
    return avg.map((v) => v / embeddings.length).toList();
  }

  // ─── Step 1: Name Entry Screen ────────────────────────────────────────────

  Widget _buildNameEntry() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            const Text('Full Name',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 10),
            TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'e.g. Juan Dela Cruz',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Colors.tealAccent, width: 1.5),
                ),
                prefixIcon:
                    const Icon(Icons.person, color: Colors.white38),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Name is required';
                if (v.trim().length < 2) return 'Name is too short';
                return null;
              },
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Proceed to Face Scan',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    setState(() => _step = RegistrationStep.scanFace);
                    _initCamera();
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Step 2: Face Scan Screen ─────────────────────────────────────────────

  Widget _buildFaceScan() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.teal));
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    final progress = _capturedEmbeddings.length / _requiredSamples;

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
            scale: scale, child: Center(child: CameraPreview(_cameraController!))),

        // Dark overlay gradient
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            height: 200,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
          ),
        ),

        // Oval guide
        Center(
          child: CustomPaint(
            size: Size(size.width, size.height),
            painter: _OvalPainter(progress: progress),
          ),
        ),

        // Status + progress
        Positioned(
          bottom: 48,
          left: 24,
          right: 24,
          child: Column(
            children: [
              LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                borderRadius: BorderRadius.circular(4),
                minHeight: 6,
              ),
              const SizedBox(height: 12),
              Text(
                _statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Step 3: Result Screen ────────────────────────────────────────────────

  Widget _buildResult() {
    final isSuccess = _step == RegistrationStep.success;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSuccess ? Icons.check_circle_outline : Icons.error_outline,
              color: isSuccess ? Colors.tealAccent : Colors.redAccent,
              size: 90,
            ),
            const SizedBox(height: 24),
            Text(
              isSuccess ? 'Registration Successful!' : 'Registration Failed',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              isSuccess ? _statusMessage : _errorMessage,
              style: const TextStyle(color: Colors.white60, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: 200,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isSuccess ? Colors.teal : Colors.white12,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  isSuccess ? 'Done' : 'Go Back',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Main Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    String title = switch (_step) {
      RegistrationStep.enterName => 'Register Employee',
      RegistrationStep.scanFace => 'Face Scan',
      RegistrationStep.processing => 'Saving…',
      RegistrationStep.success => 'Done',
      RegistrationStep.error => 'Error',
    };

    Widget body = switch (_step) {
      RegistrationStep.enterName => _buildNameEntry(),
      RegistrationStep.scanFace => _buildFaceScan(),
      RegistrationStep.processing => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.teal),
              SizedBox(height: 20),
              Text('Saving to database…',
                  style: TextStyle(color: Colors.white60)),
            ],
          ),
        ),
      RegistrationStep.success || RegistrationStep.error => _buildResult(),
    };

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(title,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: _step == RegistrationStep.scanFace
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                onPressed: () {
                  _cameraController?.stopImageStream();
                  setState(() {
                    _step = RegistrationStep.enterName;
                    _capturedEmbeddings.clear();
                    _isCameraReady = false;
                    _statusMessage = 'Position face in frame. Hold still…';
                  });
                },
              )
            : null,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: SizedBox(key: ValueKey(_step), child: body),
      ),
    );
  }
}

// ─── Oval Painter ─────────────────────────────────────────────────────────────

class _OvalPainter extends CustomPainter {
  final double progress;
  _OvalPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.42;
    final ovalW = size.width * 0.62;
    final ovalH = ovalW * 1.35;
    final rect =
        Rect.fromCenter(center: Offset(cx, cy), width: ovalW, height: ovalH);

    // Background dim oval
    canvas.drawOval(
        rect,
        Paint()
          ..color = Colors.white12
          ..style = PaintingStyle.fill);

    // Progress arc (sweeping)
    final sweep = 2 * 3.1415926 * progress;
    canvas.drawArc(
        rect,
        -3.1415926 / 2,
        sweep,
        false,
        Paint()
          ..color = Colors.tealAccent
          ..strokeWidth = 4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _OvalPainter old) => old.progress != progress;
}
