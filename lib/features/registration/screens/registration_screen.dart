import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';
import '../../../core/utils/image_utils.dart';
import '../../face_recognition/services/face_recognition_service.dart';
import '../../attendance/providers/attendance_provider.dart';
import '../providers/employee_provider.dart';

enum RegistrationStep { enterName, scanFace, processing, success, error }

/// Each pose the user must hold. `done` is a terminal sentinel — never shown.
enum RegistrationPose { front, left, right, up, blink, done }

class RegistrationScreen extends ConsumerStatefulWidget {
  final Employee? editEmployee;
  const RegistrationScreen({super.key, this.editEmployee});

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  // ── Form controllers ─────────────────────────────────────────────────────
  final _nameController     = TextEditingController();
  final _emailController    = TextEditingController();
  final _empIdController    = TextEditingController();
  final _ageController      = TextEditingController();
  final _positionController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String _selectedSex        = 'Male';
  String _selectedDepartment = 'General';
  List<String> _departments  = ['General'];
  final _formKey             = GlobalKey<FormState>();
  bool _isFirstAdmin         = false;

  // ── Camera state ──────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _isCameraReady  = false;
  bool _isDetecting    = false; // live-stream detection lock
  bool _isCapturing    = false; // still-photo capture lock
  bool _faceDetected   = false; // live face presence indicator
  int  _sensorRotation = 270;
  FlashMode _flashMode = FlashMode.off;

  // ── Anti-spoofing / pose state ────────────────────────────────────────────
  /// How many stable consecutive live-stream frames we need before
  /// unlocking the "Capture" button for the current pose.
  static const int _stabilityThreshold = 3;
  int _stabilityCount = 0;

  /// Whether the blink pose was successfully completed (liveness check).
  bool _hasBlinked = false;

  RegistrationPose _currentPose = RegistrationPose.front;

  /// One averaged+normalised embedding per completed pose (5 total).
  final List<List<double>> _capturedEmbeddings = [];

  // ── Per-pose shot state (their multi-shot approach per pose) ─────────────
  /// How many still photos to take per pose — matches their 4-shot approach.
  static const int _shotsPerPose = 4;
  int _shotsTaken = 0; // progress within the current pose

  // ── UI state ──────────────────────────────────────────────────────────────
  RegistrationStep _step = RegistrationStep.enterName;
  String _statusMessage  = 'Look directly at the camera';
  String _errorMessage   = '';
  bool _obscurePassword  = true;

  // ─────────────────────────────────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final db       = DatabaseService.instance;
    final depts    = await db.getAllDepartments();
    final hasAdmin = await db.hasAdmin();

    if (!mounted) return;
    setState(() {
      _departments  = depts.map((d) => d.name).toList();
      _isFirstAdmin = !hasAdmin;

      if (widget.editEmployee != null) {
        _nameController.text     = widget.editEmployee!.name;
        _emailController.text    = widget.editEmployee!.email;
        _empIdController.text    = widget.editEmployee!.empId;
        _ageController.text      = widget.editEmployee!.age.toString();
        _positionController.text = widget.editEmployee!.position;
        _selectedSex             = widget.editEmployee!.sex;
        _selectedDepartment      = widget.editEmployee!.department;
        _usernameController.text = widget.editEmployee!.username ?? '';
        _passwordController.text = widget.editEmployee!.password ?? '';
      } else {
        db.getNextEmployeeId('EMP').then((nextId) {
          if (mounted) setState(() => _empIdController.text = nextId);
        });
        if (_departments.isNotEmpty) _selectedDepartment = _departments.first;
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _empIdController.dispose();
    _ageController.dispose();
    _positionController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    // faceDetector is owned by FaceRecognitionService — disposed via service.dispose()
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CAMERA
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _sensorRotation = front.sensorOrientation;

    _cameraController = CameraController(
      front,
      // ✅ HIGH resolution — their code uses high for sharper still photos
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    _flashMode = FlashMode.torch;
    await _cameraController!.setFlashMode(_flashMode);

    await FaceRecognitionService.instance.loadModel();

    setState(() => _isCameraReady = true);
    _startLiveDetection();
  }

  Future<void> _toggleFlash() async {
    if (_cameraController == null) return;
    final next = _flashMode == FlashMode.torch ? FlashMode.off : FlashMode.torch;
    await _cameraController!.setFlashMode(next);
    if (mounted) setState(() => _flashMode = next);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LIVE DETECTION  (pose validation + face presence indicator only)
  // ─────────────────────────────────────────────────────────────────────────

  /// Runs continuously from the image stream.
  /// Purpose: (1) show the green/white oval border when a face is present,
  ///          (2) validate the current pose so we can unlock the capture button,
  ///          (3) accumulate stability frames for the front pose.
  void _startLiveDetection() {
    _cameraController!.startImageStream((CameraImage image) async {
      if (_isDetecting || _isCapturing) return;
      if (_step != RegistrationStep.scanFace) return;
      if (_currentPose == RegistrationPose.done) return;

      _isDetecting = true;
      try {
        final inputImage = _buildInputImage(image);
        if (inputImage == null) return;

        final faces = await FaceRecognitionService.instance
            .faceDetector
            .processImage(inputImage);

        if (!mounted) return;

        if (faces.isEmpty) {
          setState(() {
            _faceDetected   = false;
            _stabilityCount = 0;
            _statusMessage  = 'No face detected. Move closer.';
          });
          return;
        }

        // Pick the largest detected face (their approach — don't reject)
        final face = faces.reduce((a, b) =>
            a.boundingBox.width > b.boundingBox.width ? a : b);

        final isPoseValid = _checkPose(face);

        if (isPoseValid) {
          if (_stabilityCount < _stabilityThreshold) {
            _stabilityCount++;
            setState(() {
              _faceDetected  = true;
              _statusMessage = 'Hold still… ($_stabilityCount/$_stabilityThreshold)';
            });
          } else {
            // Pose confirmed and stable — unlock capture button
            setState(() {
              _faceDetected  = true;
              _statusMessage = _capturePromptForPose(_currentPose);
            });
          }
        } else {
          _stabilityCount = 0;
          setState(() {
            _faceDetected  = true; // face IS present, just wrong angle
            _statusMessage = _instructionForPose(_currentPose);
          });
        }
      } catch (e) {
        debugPrint('[Registration] Live detection error: $e');
      } finally {
        _isDetecting = false;
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // POSE CAPTURE  (their still-photo approach, per pose)
  // ─────────────────────────────────────────────────────────────────────────

  /// Called when the user taps the capture button for the current pose.
  ///
  /// ✅ KEY IMPROVEMENT (from their code): we stop the stream, take
  /// [_shotsPerPose] still JPEG photos via [takePicture()], detect the face
  /// from the file, and generate the embedding from the clean JPEG.
  /// This is dramatically more accurate than extracting from a YUV stream
  /// frame because still photos are fully processed by the ISP (white balance,
  /// noise reduction, sharpening) whereas stream frames are raw/compressed.
  Future<void> _capturePose() async {
    if (_isCapturing || !_faceDetected || _stabilityCount < _stabilityThreshold)
      return;

    setState(() {
      _isCapturing = true;
      _shotsTaken  = 0;
      _statusMessage = 'Starting capture…';
    });

    // Pause live detection while we take stills
    await _cameraController!.stopImageStream();
    await Future.delayed(const Duration(milliseconds: 150));

    try {
      final List<List<double>> poseEmbeddings = [];

      for (int shot = 1; shot <= _shotsPerPose; shot++) {
        if (!mounted) return;

        setState(() => _statusMessage =
            '${_poseLabel(_currentPose)} — shot $shot of $_shotsPerPose…');

        // ── Take still photo ───────────────────────────────────────────────
        final xFile = await _cameraController!.takePicture();

        // ── Detect face from file (cleaner than stream frame) ──────────────
        final inputImage = InputImage.fromFile(File(xFile.path));
        final allFaces   = await FaceRecognitionService.instance
            .faceDetector
            .processImage(inputImage);

        if (allFaces.isEmpty) {
          _showSnackError('Shot $shot: No face found. Try again.');
          _resetToLiveDetection();
          return;
        }

        // Largest face (their approach)
        final face = allFaces.reduce((a, b) =>
            a.boundingBox.width > b.boundingBox.width ? a : b);

        // ── BLINK LIVENESS CHECK (anti-spoof) ─────────────────────────────
        // For the blink pose we check eye-open probability on the still photo.
        if (_currentPose == RegistrationPose.blink) {
          final leftOpen  = face.leftEyeOpenProbability  ?? 1.0;
          final rightOpen = face.rightEyeOpenProbability ?? 1.0;
          if (leftOpen < 0.4 && rightOpen < 0.4) {
            _hasBlinked = true;
          }
        }

        // ── Generate embedding from still file ─────────────────────────────
        // ✅ THEIR APPROACH: generateEmbeddingFromFile reads the clean JPEG,
        //    crops by the ML Kit bounding box, and runs FaceNet — much better
        //    quality than decoding a YUV stream frame manually.
        final embedding = await FaceRecognitionService.instance
            .generateEmbeddingFromFile(xFile.path, face);

        if (embedding == null) {
          _showSnackError('Shot $shot failed. Improve lighting and retry.');
          _resetToLiveDetection();
          return;
        }

        // ── Duplicate check on very first shot of the front pose ───────────
        if (_currentPose == RegistrationPose.front && shot == 1) {
          final db           = DatabaseService.instance;
          final allEmployees = await db.getAllEmployees();
          final knownFaces   = allEmployees
              .where((e) =>
                  e.facialEmbedding.isNotEmpty &&
                  (widget.editEmployee == null ||
                      e.id != widget.editEmployee!.id))
              .map((e) => MapEntry(e.name, e.facialEmbedding))
              .toList();

          final duplicateName = FaceRecognitionService.checkDuplicateEmbedding(
              embedding, knownFaces);
          if (duplicateName != null) {
            final bool? cont = await _showDuplicateFaceWarning(duplicateName);
            if (cont != true) {
              if (mounted) {
                setState(() {
                  _step          = RegistrationStep.enterName;
                  _isCameraReady = false;
                  _capturedEmbeddings.clear();
                });
              }
              return;
            }
          }
        }

        poseEmbeddings.add(embedding);
        setState(() => _shotsTaken = shot);

        // Short pause between shots (except after last)
        if (shot < _shotsPerPose) {
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }

      // ── Average all shots for this pose ────────────────────────────────────
      final poseEmbedding =
          FaceRecognitionService.averageEmbeddings(poseEmbeddings);
      _capturedEmbeddings.add(poseEmbedding);

      _moveToNextPose();
    } catch (e) {
      debugPrint('[Registration] Capture error: $e');
      _showSnackError('Capture failed: $e');
      _resetToLiveDetection();
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // POSE NAVIGATION
  // ─────────────────────────────────────────────────────────────────────────

  void _moveToNextPose() {
    if (!mounted) return;
    _stabilityCount = 0;
    _shotsTaken     = 0;

    setState(() {
      _currentPose = RegistrationPose.values[_currentPose.index + 1];

      if (_currentPose == RegistrationPose.done) {
        _cameraController?.setFlashMode(FlashMode.off);
        // Stream is already stopped — go straight to save
        _saveEmployee();
      } else {
        _statusMessage = _instructionForPose(_currentPose);
        // Restart live detection for the next pose
        _startLiveDetection();
      }
    });
  }

  void _resetToLiveDetection() {
    if (!mounted) return;
    setState(() {
      _isCapturing    = false;
      _shotsTaken     = 0;
      _faceDetected   = false;
      _stabilityCount = 0;
      _statusMessage  = _instructionForPose(_currentPose);
    });
    _startLiveDetection();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // POSE HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  bool _checkPose(Face face) {
    final headY = face.headEulerAngleY ?? 0;
    final headX = face.headEulerAngleX ?? 0;

    return switch (_currentPose) {
      RegistrationPose.front => headY.abs() < 8 && headX.abs() < 8,
      RegistrationPose.left  => headY > 20,
      RegistrationPose.right => headY < -20,
      RegistrationPose.up    => headX > 15,
      RegistrationPose.blink =>
        (face.leftEyeOpenProbability  ?? 1.0) < 0.4 &&
        (face.rightEyeOpenProbability ?? 1.0) < 0.4,
      _ => false,
    };
  }

  String _instructionForPose(RegistrationPose pose) => switch (pose) {
    RegistrationPose.front => 'Look directly at the camera',
    RegistrationPose.left  => 'Slowly turn your head to the LEFT',
    RegistrationPose.right => 'Slowly turn your head to the RIGHT',
    RegistrationPose.up    => 'Tilt your head UPWARDS',
    RegistrationPose.blink => 'Now, BLINK your eyes',
    _                      => '',
  };

  String _capturePromptForPose(RegistrationPose pose) => switch (pose) {
    RegistrationPose.front => 'Perfect! Tap Capture',
    RegistrationPose.left  => 'Good angle! Tap Capture',
    RegistrationPose.right => 'Good angle! Tap Capture',
    RegistrationPose.up    => 'Good! Tap Capture',
    RegistrationPose.blink => 'Keep blinking! Tap Capture',
    _                      => '',
  };

  String _poseLabel(RegistrationPose pose) => switch (pose) {
    RegistrationPose.front => 'Front',
    RegistrationPose.left  => 'Left',
    RegistrationPose.right => 'Right',
    RegistrationPose.up    => 'Up',
    RegistrationPose.blink => 'Blink',
    _                      => '',
  };

  InputImage? _buildInputImage(CameraImage image) {
    if (_cameraController == null) return null;
    return buildInputImageForMLKit(
      image:  image,
      camera: _cameraController!.description,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SAVE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _saveEmployee() async {
    setState(() => _step = RegistrationStep.processing);

    try {
      final db = DatabaseService.instance;

      // ── ANTI-SPOOF GUARDS ─────────────────────────────────────────────────
      if (!_isFirstAdmin && !(widget.editEmployee?.isAdmin ?? false)) {
        if (_capturedEmbeddings.isEmpty) {
          setState(() {
            _step         = RegistrationStep.error;
            _errorMessage = 'Face scan failed. Please try again.';
          });
          return;
        }
        if (!_hasBlinked) {
          setState(() {
            _step         = RegistrationStep.error;
            _errorMessage =
                'Liveness check failed (no blink detected). Please try again.';
          });
          return;
        }
      }

      // Final cross-pose average (all 5 pose embeddings → one master embedding)
      final avgEmbedding = _capturedEmbeddings.isEmpty
          ? (widget.editEmployee?.facialEmbedding ??
              List<double>.filled(128, 0.0))
          : FaceRecognitionService.averageEmbeddings(_capturedEmbeddings);

      final name     = _nameController.text.trim();
      final email    = _emailController.text.trim();
      final age      = int.tryParse(_ageController.text.trim()) ?? 0;
      final position = _positionController.text.trim();
      final empId    = _empIdController.text.trim();

      if (widget.editEmployee != null) {
        await db.updateEmployee(Employee(
          id:              widget.editEmployee!.id,
          name:            name,
          email:           email,
          age:             age,
          sex:             _selectedSex,
          position:        position,
          department:      _selectedDepartment,
          empId:           empId,
          isAdmin:         widget.editEmployee!.isAdmin,
          facialEmbedding: avgEmbedding,
          username: widget.editEmployee!.isAdmin ? _usernameController.text : null,
          password: widget.editEmployee!.isAdmin ? _passwordController.text : null,
          isDeleted: widget.editEmployee!.isDeleted,
        ));
        _syncProviders();
        if (mounted) setState(() {
          _step          = RegistrationStep.success;
          _statusMessage = 'Profile updated successfully!';
        });
      } else {
        final bool isAdmin = _isFirstAdmin;
        await db.insertEmployee(Employee(
          name:            name,
          email:           email,
          age:             age,
          sex:             _selectedSex,
          position:        position,
          department:      _selectedDepartment,
          empId:           empId,
          isAdmin:         isAdmin,
          facialEmbedding: avgEmbedding,
          username: isAdmin ? _usernameController.text.trim() : null,
          password: isAdmin ? _passwordController.text.trim() : null,
        ));
        _syncProviders();
        if (mounted) setState(() {
          _step          = RegistrationStep.success;
          _statusMessage = isAdmin
              ? '$name registered as SYSTEM ADMIN!'
              : '$name has been registered! ID: $empId';
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _step         = RegistrationStep.error;
        _errorMessage = 'Failed to save: $e';
      });
    }
  }

  void _syncProviders() {
    ref.invalidate(employeesProvider);
    ref.invalidate(currentlyWorkingProvider);
    ref.invalidate(absentTodayProvider);
    ref.invalidate(attendanceLogsTodayProvider);
    ref.invalidate(attendanceLogsWithNamesProvider);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DIALOGS / SNACKBARS
  // ─────────────────────────────────────────────────────────────────────────

  void _showSnackError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.redAccent,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<bool?> _showDuplicateFaceWarning(String? matchedName) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Possible Duplicate Face',
            style: TextStyle(color: Colors.orangeAccent)),
        content: Text(
          'This face appears to match an already registered employee: '
          '$matchedName.\n\nAre you sure you want to proceed?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            child: const Text('Proceed Anyway'),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI — STEP 1: NAME ENTRY
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildNameEntry() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Personal Information',
                style: TextStyle(
                    color: Colors.tealAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),

            _buildFieldLabel('Full Name'),
            TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration('e.g. Juan Dela Cruz', Icons.person),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 20),

            Row(children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('Email Address'),
                    TextFormField(
                      controller: _emailController,
                      style: const TextStyle(color: Colors.white),
                      decoration: _buildInputDecoration(
                          'name@company.com', Icons.email_outlined),
                      keyboardType: TextInputType.emailAddress,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('Employee ID'),
                    TextFormField(
                      controller: _empIdController,
                      enabled: false,
                      style: const TextStyle(color: Colors.white60),
                      decoration:
                          _buildInputDecoration('ID-XXX', Icons.badge_outlined),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 20),

            Row(children: [
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('Age'),
                    TextFormField(
                      controller: _ageController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white),
                      decoration: _buildInputDecoration('00', Icons.cake),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFieldLabel('Sex'),
                    DropdownButtonFormField<String>(
                      value: _selectedSex,
                      dropdownColor: const Color(0xFF161B22),
                      style: const TextStyle(color: Colors.white),
                      decoration: _buildInputDecoration('', Icons.people),
                      items: ['Male', 'Female', 'Other']
                          .map((s) =>
                              DropdownMenuItem(value: s, child: Text(s)))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedSex = v!),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 20),

            _buildFieldLabel('Company Position'),
            TextFormField(
              controller: _positionController,
              style: const TextStyle(color: Colors.white),
              decoration:
                  _buildInputDecoration('e.g. Software Engineer', Icons.work),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Position is required'
                  : null,
            ),
            const SizedBox(height: 20),

            _buildFieldLabel('Company'),
            DropdownButtonFormField<String>(
              value: _selectedDepartment,
              dropdownColor: const Color(0xFF161B22),
              style: const TextStyle(color: Colors.white),
              decoration:
                  _buildInputDecoration('', Icons.business_rounded),
              items: _departments
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedDepartment = v!),
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Required' : null,
            ),

            if (_isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)) ...[
              const SizedBox(height: 32),
              const Text('Admin Security Credentials',
                  style: TextStyle(
                      color: Colors.tealAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _buildFieldLabel('Admin Username'),
              TextFormField(
                controller: _usernameController,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration(
                    'Username', Icons.admin_panel_settings),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Username is required'
                    : null,
              ),
              const SizedBox(height: 16),
              _buildFieldLabel('Admin Password'),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration(
                  'Password',
                  Icons.lock,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: Colors.white38,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Password is required';
                  if (v.length < 8) return 'Minimum 8 characters';
                  if (!v.contains(RegExp(r'[A-Z]'))) return 'Add an uppercase letter';
                  if (!v.contains(RegExp(r'[0-9]'))) return 'Add a number';
                  if (!v.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-]')))
                    return 'Add a special character';
                  return null;
                },
              ),
            ],

            const SizedBox(height: 48),

            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton.icon(
                icon: Icon(
                  _isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)
                      ? Icons.save_rounded
                      : Icons.camera_alt_outlined,
                ),
                label: Text(
                  _isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)
                      ? 'Save Admin Account'
                      : 'Proceed to Face Recognition',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () async {
                  if (!_formKey.currentState!.validate()) return;

                  if (_isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)) {
                    _saveEmployee();
                    return;
                  }

                  final db        = DatabaseService.instance;
                  final employees = await db.getAllEmployees();
                  final name  = _nameController.text.trim().toLowerCase();
                  final empId = _empIdController.text.trim().toLowerCase();

                  final bool exists = employees.any((e) =>
                      (e.name.toLowerCase() == name ||
                          e.empId.toLowerCase() == empId) &&
                      e.id != widget.editEmployee?.id);

                  if (exists && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content:
                          Text('Employee with this Name or ID already exists!'),
                      backgroundColor: Colors.redAccent,
                    ));
                    return;
                  }

                  setState(() {
                    _step        = RegistrationStep.scanFace;
                    _currentPose = RegistrationPose.front;
                  });
                  _initCamera();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8.0),
    child: Text(label,
        style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w500)),
  );

  InputDecoration _buildInputDecoration(String hint, IconData icon,
      {Widget? suffixIcon}) {
    return InputDecoration(
      hintText:   hint,
      hintStyle:  const TextStyle(color: Colors.white38),
      suffixIcon: suffixIcon,
      filled:     true,
      fillColor:  Colors.white10,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:
              const BorderSide(color: Colors.tealAccent, width: 1.5)),
      prefixIcon: Icon(icon, color: Colors.white38, size: 20),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI — STEP 2: FACE SCAN
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildFaceScan() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.teal));
    }

    final size  = MediaQuery.of(context).size;
    var scale   = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    // Progress: how many poses are done out of 5
    final progress = _capturedEmbeddings.length / 5.0;

    // Is the capture button active?
    final bool canCapture = _faceDetected &&
        _stabilityCount >= _stabilityThreshold &&
        !_isCapturing;

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Camera preview ──────────────────────────────────────────────────
        Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(_cameraController!))),

        // ── Oval overlay ────────────────────────────────────────────────────
        Center(
          child: CustomPaint(
            size: Size(size.width, size.height),
            painter: _GuidedOvalPainter(
              pose:       _currentPose,
              progress:   progress,
              faceActive: _faceDetected,
              poseValid:  canCapture,
            ),
          ),
        ),

        // ── Flash toggle ────────────────────────────────────────────────────
        Positioned(
          top: 50, right: 20,
          child: Column(children: [
            FloatingActionButton.small(
              onPressed: _toggleFlash,
              backgroundColor: _flashMode == FlashMode.torch
                  ? Colors.tealAccent
                  : Colors.black54,
              child: Icon(
                _flashMode == FlashMode.torch
                    ? Icons.flash_on
                    : Icons.flash_off,
                color: _flashMode == FlashMode.torch
                    ? Colors.black87
                    : Colors.white70,
              ),
            ),
            const SizedBox(height: 4),
            const Text('FLASH',
                style: TextStyle(
                    color: Colors.white60,
                    fontSize: 10,
                    fontWeight: FontWeight.bold)),
          ]),
        ),

        // ── Pose graphic ────────────────────────────────────────────────────
        Positioned(
          top: 100, left: 0, right: 0,
          child: Center(child: _PoseGraphic(pose: _currentPose)),
        ),

        // ── Bottom status + capture button ───────────────────────────────────
        Positioned(
          bottom: 36, left: 24, right: 24,
          child: Column(
            children: [
              // Status text
              Text(
                _statusMessage,
                style: TextStyle(
                  color: canCapture ? Colors.tealAccent : Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              // Shot progress dots (visible while capturing)
              if (_isCapturing)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_shotsPerPose, (i) {
                    final done   = i < _shotsTaken;
                    final active = i == _shotsTaken && _isCapturing;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      width:  active ? 18 : 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: done
                            ? Colors.tealAccent
                            : active
                                ? Colors.tealAccent.withOpacity(0.5)
                                : Colors.white24,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    );
                  }),
                ),

              const SizedBox(height: 10),

              // Pose progress bar
              LinearProgressIndicator(
                value:           progress,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(
                    Colors.tealAccent),
                borderRadius: BorderRadius.circular(4),
                minHeight:    8,
              ),
              const SizedBox(height: 6),
              Text(
                'Pose: ${_capturedEmbeddings.length + 1} of 5',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),

              const SizedBox(height: 20),

              // ── CAPTURE BUTTON (their explicit tap approach) ──────────────
              // Instead of auto-capturing from stream, the user taps when ready.
              // This avoids capturing a transitional / blurry frame.
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: canCapture ? _capturePose : null,
                  icon: _isCapturing
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.camera_alt_rounded, size: 22),
                  label: Text(
                    _isCapturing
                        ? _statusMessage
                        : canCapture
                            ? 'Capture ${_poseLabel(_currentPose)}'
                            : _faceDetected
                                ? 'Hold pose…'
                                : 'Waiting for face…',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        canCapture ? Colors.teal : Colors.white12,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white12,
                    disabledForegroundColor: Colors.white38,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI — STEP 3: RESULT
  // ─────────────────────────────────────────────────────────────────────────

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
                onPressed: () {
                  if (isSuccess) {
                    if (widget.editEmployee == null && _isFirstAdmin) {
                      Navigator.of(context)
                          .pushNamedAndRemoveUntil('/', (r) => false);
                    } else {
                      Navigator.of(context).pop();
                    }
                  } else {
                    Navigator.of(context).pop();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSuccess ? Colors.teal : Colors.white12,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  isSuccess ? 'Continue' : 'Go Back',
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

  // ─────────────────────────────────────────────────────────────────────────
  // MAIN BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      RegistrationStep.enterName  =>
          widget.editEmployee != null ? 'Update Profile' : 'Register Employee',
      RegistrationStep.scanFace   =>
          widget.editEmployee != null ? 'Re-enroll Face' : 'Enroll Face',
      RegistrationStep.processing =>
          widget.editEmployee != null ? 'Updating…' : 'Enrolling…',
      RegistrationStep.success    => 'Complete',
      RegistrationStep.error      => 'Failure',
    };

    final body = switch (_step) {
      RegistrationStep.enterName  => _buildNameEntry(),
      RegistrationStep.scanFace   => _buildFaceScan(),
      RegistrationStep.processing => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.teal),
            SizedBox(height: 20),
            Text('Optimizing facial profile…',
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
        elevation:       0,
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
                    _step             = RegistrationStep.enterName;
                    _capturedEmbeddings.clear();
                    _currentPose      = RegistrationPose.front;
                    _isCameraReady    = false;
                    _faceDetected     = false;
                    _stabilityCount   = 0;
                    _hasBlinked       = false;
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

// ─────────────────────────────────────────────────────────────────────────────
// POSE GRAPHIC
// ─────────────────────────────────────────────────────────────────────────────

class _PoseGraphic extends StatelessWidget {
  final RegistrationPose pose;
  const _PoseGraphic({required this.pose});

  @override
  Widget build(BuildContext context) {
    final (icon, offset) = switch (pose) {
      RegistrationPose.front => (Icons.face_retouching_natural, Offset.zero),
      RegistrationPose.left  => (Icons.arrow_back,    const Offset(-40, 0)),
      RegistrationPose.right => (Icons.arrow_forward, const Offset(40,  0)),
      RegistrationPose.up    => (Icons.arrow_upward,  const Offset(0, -40)),
      RegistrationPose.blink => (Icons.remove_red_eye_outlined, Offset.zero),
      _                      => (Icons.check, Offset.zero),
    };

    return TweenAnimationBuilder<Offset>(
      duration: const Duration(milliseconds: 400),
      curve:    Curves.elasticOut,
      tween:    Tween(begin: Offset.zero, end: offset),
      builder:  (_, val, __) => Transform.translate(
        offset: val,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: Colors.teal.withAlpha(200), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 40),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GUIDED OVAL PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class _GuidedOvalPainter extends CustomPainter {
  final RegistrationPose pose;
  final double progress;
  final bool faceActive;
  final bool poseValid;

  _GuidedOvalPainter({
    required this.pose,
    required this.progress,
    required this.faceActive,
    required this.poseValid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx    = size.width / 2;
    final cy    = size.height * 0.45;
    final ovalW = size.width * 0.65;
    final ovalH = ovalW * 1.35;
    final rect  = Rect.fromCenter(
        center: Offset(cx, cy), width: ovalW, height: ovalH);

    // Dim outside
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addOval(rect),
      ),
      Paint()..color = Colors.black54,
    );

    // Oval border — green when pose is valid, teal when face detected, grey otherwise
    final borderColor = poseValid
        ? const Color(0xFF00E676)
        : faceActive
            ? Colors.tealAccent
            : Colors.white24;

    canvas.drawOval(
      rect,
      Paint()
        ..color      = borderColor
        ..strokeWidth = 3
        ..style      = PaintingStyle.stroke,
    );

    // Progress arc
    if (pose != RegistrationPose.done) {
      canvas.drawArc(
        rect,
        -3.14159 / 2,
        2 * 3.14159 * progress,
        false,
        Paint()
          ..color      = Colors.tealAccent
          ..strokeWidth = 6
          ..style      = PaintingStyle.stroke
          ..strokeCap  = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GuidedOvalPainter old) =>
      old.pose != pose ||
      old.progress != progress ||
      old.faceActive != faceActive ||
      old.poseValid != poseValid;
}