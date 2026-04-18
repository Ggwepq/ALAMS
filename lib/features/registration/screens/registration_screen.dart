import 'dart:async';
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

// States for the overall registration flow
enum RegistrationStep { enterName, scanFace, processing, success, error }

enum RegistrationPose { 
  front, 
  left, 
  right, 
  up, 
  blink,
  done 
}

class RegistrationScreen extends ConsumerStatefulWidget {
  final Employee? editEmployee;
  const RegistrationScreen({super.key, this.editEmployee});

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  // ── Profile data
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _empIdController = TextEditingController();
  final _ageController = TextEditingController();
  final _positionController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String _selectedSex = 'Male';
  String _selectedDepartment = 'General';
  List<String> _departments = ['General'];
  final _formKey = GlobalKey<FormState>();
  bool _isFirstAdmin = false;

  // ── Camera & Recognition
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _isProcessingFrame = false;

  // ── Guided Registration State
  RegistrationPose _currentPose = RegistrationPose.front;
  final List<List<double>> _capturedEmbeddings = [];
  
  // ── ML Kit face detector
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true, // Need this for blink step
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.2,
    ),
  );

  RegistrationStep _step = RegistrationStep.enterName;
  String _statusMessage = 'Look directly at the camera';
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final db = DatabaseService.instance;
    final depts = await db.getAllDepartments();
    final count = await db.getEmployeeCount();
    final hasAdmin = await db.hasAdmin();
    
    if (mounted) {
      setState(() {
        _departments = depts.map((d) => d.name).toList();
        _isFirstAdmin = !hasAdmin;
        
        if (widget.editEmployee != null) {
          _nameController.text = widget.editEmployee!.name;
          _emailController.text = widget.editEmployee!.email;
          _empIdController.text = widget.editEmployee!.empId;
          _ageController.text = widget.editEmployee!.age.toString();
          _positionController.text = widget.editEmployee!.position;
          _selectedSex = widget.editEmployee!.sex;
          _selectedDepartment = widget.editEmployee!.department;
          _usernameController.text = widget.editEmployee!.username ?? '';
          _passwordController.text = widget.editEmployee!.password ?? '';
        } else {
          // Auto-generate ID if not editing
          _empIdController.text = 'EMP-${(count + 1).toString().padLeft(3, '0')}';
          if (_departments.isNotEmpty) {
            _selectedDepartment = _departments.first;
          }
        }
      });
    }
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

  // ─── Guided Frame Processing ──────────────────────────────────────────────

  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  void _onFrame(CameraImage image) async {
    if (_isProcessingFrame || _step != RegistrationStep.scanFace) return;
    if (_currentPose == RegistrationPose.done) return;

    final now = DateTime.now();
    // Slightly faster processing for registration feel
    if (now.difference(_lastProcessed) < const Duration(milliseconds: 300)) return;
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

      final face = faces.first;
      final bool isPoseValid = _checkPose(face);

      if (isPoseValid) {
        // Generate embedding for this specific pose
        final faceService = FaceRecognitionService.instance;
        final preprocessed = FaceRecognitionService.preprocessCameraImage(image);
        if (preprocessed != null) {
          final embedding = faceService.generateEmbedding(preprocessed);
          if (embedding != null) {
            _capturedEmbeddings.add(embedding);
            _moveToNextPose();
          }
        }
      } else {
        _updateInstructionForPose();
      }
    } catch (e) {
      debugPrint('[Registration] Error: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  bool _checkPose(Face face) {
    final headY = face.headEulerAngleY ?? 0; // turn (left/right)
    final headX = face.headEulerAngleX ?? 0; // tilt (up/down)

    return switch (_currentPose) {
      RegistrationPose.front => headY.abs() < 8 && headX.abs() < 8,
      RegistrationPose.left => headY > 20,
      RegistrationPose.right => headY < -20,
      RegistrationPose.up => headX > 15,
      RegistrationPose.blink => (face.leftEyeOpenProbability ?? 1.0) < 0.4 && 
                                 (face.rightEyeOpenProbability ?? 1.0) < 0.4,
      _ => false,
    };
  }

  void _moveToNextPose() {
    if (!mounted) return;
    setState(() {
      _currentPose = RegistrationPose.values[_currentPose.index + 1];
      if (_currentPose == RegistrationPose.done) {
        _cameraController?.stopImageStream();
        _saveEmployee();
      } else {
        _updateInstructionForPose();
      }
    });
  }

  void _updateInstructionForPose() {
    if (!mounted) return;
    final msg = switch (_currentPose) {
      RegistrationPose.front => 'Look directly at the camera',
      RegistrationPose.left => 'Slowly turn your head to the LEFT',
      RegistrationPose.right => 'Slowly turn your head to the RIGHT',
      RegistrationPose.up => 'Tilt your head UPWARDS',
      RegistrationPose.blink => 'Now, BLINK your eyes',
      _ => '',
    };
    if (_statusMessage != msg) {
      setState(() => _statusMessage = msg);
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
      final db = DatabaseService.instance;
      // Admins (initial or edited) might skip face scan
      final avgEmbedding = _capturedEmbeddings.isEmpty 
          ? List<double>.filled(128, 0.0) 
          : _averageEmbeddings(_capturedEmbeddings);
          
      final name = _nameController.text.trim();
      final email = _emailController.text.trim();
      final age = int.tryParse(_ageController.text.trim()) ?? 0;
      final position = _positionController.text.trim();
      final empId = _empIdController.text.trim();

      if (widget.editEmployee != null) {
        // EDIT MODE
        final updated = Employee(
          id: widget.editEmployee!.id,
          name: name,
          email: email,
          age: age,
          sex: _selectedSex,
          position: position,
          department: _selectedDepartment,
          empId: empId,
          isAdmin: widget.editEmployee!.isAdmin,
          facialEmbedding: avgEmbedding,
          username: widget.editEmployee!.isAdmin ? _usernameController.text : null,
          password: widget.editEmployee!.isAdmin ? _passwordController.text : null,
        );
        await db.updateEmployee(updated);
        
        // Sync real-time UI
        _syncProviders();
        
        if (mounted) {
          setState(() {
            _step = RegistrationStep.success;
            _statusMessage = 'Profile updated successfully!';
          });
        }
      } else {
        // ENROLL MODE
        final bool isAdmin = _isFirstAdmin;

        await db.insertEmployee(
          Employee(
            name: name,
            email: email,
            age: age,
            sex: _selectedSex,
            position: position,
            department: _selectedDepartment,
            empId: empId,
            isAdmin: isAdmin,
            facialEmbedding: avgEmbedding,
            username: isAdmin ? _usernameController.text.trim() : null,
            password: isAdmin ? _passwordController.text.trim() : null,
          ),
        );

        // Sync real-time UI
        _syncProviders();

        if (mounted) {
          setState(() {
            _step = RegistrationStep.success;
            _statusMessage = isAdmin 
                ? '$name registered as SYSTEM ADMIN!' 
                : '$name has been registered! ID: $empId';
          });
        }
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

  void _syncProviders() {
    // Invalidate everything to force a clean re-fetch across the app
    ref.invalidate(employeesProvider);
    ref.invalidate(currentlyWorkingProvider);
    ref.invalidate(absentTodayProvider);
    ref.invalidate(attendanceLogsWithNamesProvider);
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Personal Information',
                style: TextStyle(color: Colors.tealAccent, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            
            // Name
            _buildFieldLabel('Full Name'),
            TextFormField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration('e.g. Juan Dela Cruz', Icons.person),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 20),

            // Email & ID
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Email Address'),
                      TextFormField(
                        controller: _emailController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _buildInputDecoration('name@company.com', Icons.email_outlined),
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
                        decoration: _buildInputDecoration('ID-XXX', Icons.badge_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                // Age
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
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Sex
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
                            .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                            .toList(),
                        onChanged: (v) => setState(() => _selectedSex = v!),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Position
            _buildFieldLabel('Company Position'),
            TextFormField(
              controller: _positionController,
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration('e.g. Software Engineer', Icons.work),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Position is required' : null,
            ),
            const SizedBox(height: 20),

            // Department
            _buildFieldLabel('Department'),
            DropdownButtonFormField<String>(
              value: _selectedDepartment,
              dropdownColor: const Color(0xFF161B22),
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration('', Icons.business_rounded),
              items: _departments
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedDepartment = v!),
              validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
            ),

            if (_isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)) ...[
              const SizedBox(height: 32),
              const Text('Admin Security Credentials',
                  style: TextStyle(color: Colors.tealAccent, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _buildFieldLabel('Admin Username'),
              TextFormField(
                controller: _usernameController,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration('Username', Icons.admin_panel_settings),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Username is required' : null,
              ),
              const SizedBox(height: 16),
              _buildFieldLabel('Admin Password'),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration('Password', Icons.lock),
                validator: (v) => (v == null || v.trim().length < 4) ? 'Password must be 4+ characters' : null,
              ),
            ],

            const SizedBox(height: 48),
            
            const SizedBox(height: 48),
            
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton.icon(
                icon: Icon(_isFirstAdmin || (widget.editEmployee?.isAdmin ?? false) ? Icons.save_rounded : Icons.camera_alt_outlined),
                label: Text(
                  _isFirstAdmin || (widget.editEmployee?.isAdmin ?? false) 
                      ? 'Save Admin Account' 
                      : 'Proceed to Face Recognition', 
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () {
                  if (_formKey.currentState!.validate()) {
                    if (_isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)) {
                      _saveEmployee();
                    } else {
                      setState(() {
                        _step = RegistrationStep.scanFace;
                        _currentPose = RegistrationPose.front;
                      });
                      _initCamera();
                    }
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(label,
          style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
    );
  }

  InputDecoration _buildInputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      filled: true,
      fillColor: Colors.white10,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.tealAccent, width: 1.5)),
      prefixIcon: Icon(icon, color: Colors.white38, size: 20),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  // ─── Step 2: Face Scan Screen ─────────────────────────────────────────────

  Widget _buildFaceScan() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.teal));
    }

    final size = MediaQuery.of(context).size;
    var scale = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    final progress = _capturedEmbeddings.length / 5.0; // 5 poses

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(scale: scale, child: Center(child: CameraPreview(_cameraController!))),

        // Oval guide & graphics
        Center(
          child: CustomPaint(
            size: Size(size.width, size.height),
            painter: _GuidedOvalPainter(pose: _currentPose, progress: progress),
          ),
        ),

        // Pose Indicator Graphic
        Positioned(
          top: 100,
          left: 0,
          right: 0,
          child: Center(child: _PoseGraphic(pose: _currentPose)),
        ),

        // Status + progress
        Positioned(
          bottom: 48,
          left: 24,
          right: 24,
          child: Column(
            children: [
              Text(
                _statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                borderRadius: BorderRadius.circular(4),
                minHeight: 8,
              ),
              const SizedBox(height: 8),
              Text('Step ${_capturedEmbeddings.length + 1} of 5', style: const TextStyle(color: Colors.white60, fontSize: 12)),
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
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
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
                      // Reset stack to trigger RootGuardian re-check for the new admin
                      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
                    } else {
                      // Return to dashboard or employee list
                      Navigator.of(context).pop();
                    }
                  } else {
                    Navigator.of(context).pop();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSuccess ? Colors.teal : Colors.white12,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(isSuccess ? 'Continue' : 'Go Back', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
      RegistrationStep.enterName => widget.editEmployee != null ? 'Update Profile' : 'Register Employee',
      RegistrationStep.scanFace => widget.editEmployee != null ? 'Re-enroll Face' : 'Enroll Face',
      RegistrationStep.processing => widget.editEmployee != null ? 'Updating…' : 'Enrolling…',
      RegistrationStep.success => 'Complete',
      RegistrationStep.error => 'Failure',
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
              Text('Optimizing facial profile…', style: TextStyle(color: Colors.white60)),
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
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: _step == RegistrationStep.scanFace
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                onPressed: () {
                  _cameraController?.stopImageStream();
                  setState(() {
                    _step = RegistrationStep.enterName;
                    _capturedEmbeddings.clear();
                    _currentPose = RegistrationPose.front;
                    _isCameraReady = false;
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

// ─── Poses Graphic ──────────────────────────────────────────────────────────

class _PoseGraphic extends StatelessWidget {
  final RegistrationPose pose;
  const _PoseGraphic({required this.pose});

  @override
  Widget build(BuildContext context) {
    final (icon, offset) = switch (pose) {
      RegistrationPose.front => (Icons.face_retouching_natural, Offset.zero),
      RegistrationPose.left => (Icons.arrow_back, const Offset(-40, 0)),
      RegistrationPose.right => (Icons.arrow_forward, const Offset(40, 0)),
      RegistrationPose.up => (Icons.arrow_upward, const Offset(0, -40)),
      RegistrationPose.blink => (Icons.remove_red_eye_outlined, Offset.zero),
      _ => (Icons.check, Offset.zero),
    };

    return TweenAnimationBuilder<Offset>(
      duration: const Duration(milliseconds: 400),
      curve: Curves.elasticOut,
      tween: Tween(begin: Offset.zero, end: offset),
      builder: (context, val, child) {
        return Transform.translate(
          offset: val,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.teal.withAlpha(200), shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 40),
          ),
        );
      },
    );
  }
}

// ─── Guided Oval Painter ──────────────────────────────────────────────────────

class _GuidedOvalPainter extends CustomPainter {
  final RegistrationPose pose;
  final double progress;
  _GuidedOvalPainter({required this.pose, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.42;
    final ovalW = size.width * 0.62;
    final ovalH = ovalW * 1.35;
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: ovalW, height: ovalH);

    // Background dim
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Rect.fromLTWH(0,0,size.width,size.height)), Path()..addOval(rect)),
      Paint()..color = Colors.black54
    );

    // Progress Border
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    canvas.drawOval(rect, paint);

    // Active Sector (based on pose)
    final activePaint = Paint()
      ..color = Colors.tealAccent
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    if (pose != RegistrationPose.done) {
       final sweep = 2 * 3.14159 * progress;
       canvas.drawArc(rect, -3.14159/2, sweep, false, activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GuidedOvalPainter old) => old.pose != pose || old.progress != progress;
}

