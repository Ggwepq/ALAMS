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

  CameraController? _cameraController;
  bool _isCameraReady      = false;
  bool _isProcessingFrame  = false;
  int _stabilityCount      = 0;
  bool _hasBlinked         = false;
  final int _stabilityThreshold = 3; // ~1 second with 300ms throttling

  RegistrationPose _currentPose = RegistrationPose.front;
  final List<List<double>> _capturedEmbeddings = [];

  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.2,
    ),
  );

  RegistrationStep _step          = RegistrationStep.enterName;
  String _statusMessage           = 'Look directly at the camera';
  String _errorMessage            = '';
  bool _obscurePassword           = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final db    = DatabaseService.instance;
    final depts = await db.getAllDepartments();
    final count = await db.getEmployeeCount();
    final hasAdmin = await db.hasAdmin();

    if (mounted) {
      setState(() {
        _departments = depts.map((d) => d.name).toList();
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

    // Ensure model is loaded before starting stream
    await FaceRecognitionService.instance.loadModel();
    _cameraController!.startImageStream(_onFrame);
  }

  // ─── Guided Frame Processing ──────────────────────────────────────────────

  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  void _onFrame(CameraImage image) async {
    if (_isProcessingFrame || _step != RegistrationStep.scanFace) return;
    if (_currentPose == RegistrationPose.done) return;

    final now = DateTime.now();
    if (now.difference(_lastProcessed) < const Duration(milliseconds: 300)) return;
    _lastProcessed = now;

    _isProcessingFrame = true;

    try {
      // Ensure model is loaded
      final faceService = FaceRecognitionService.instance;
      if (!faceService.isLoaded) {
        await faceService.loadModel();
        return; // skip this frame, try next
      }

      final inputImage = _buildInputImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      if (faces.isEmpty) {
        if (mounted) setState(() => _statusMessage = 'No face detected. Move closer.');
        return;
      }

      final face         = faces.first;
      final bool isPoseValid = _checkPose(face);

      if (isPoseValid) {
        if (_currentPose == RegistrationPose.front && _stabilityCount < _stabilityThreshold) {
          _stabilityCount++;
          if (mounted) setState(() => _statusMessage = 'Hold still... (${_stabilityCount}/${_stabilityThreshold})');
          return;
        }

        if (_currentPose == RegistrationPose.blink) {
          _hasBlinked = true;
        }

        final preprocessed = FaceRecognitionService.preprocessCameraImage({
          'image': image,
          'cropRect': _getOvalBufferRect(image.width, image.height),
        });
        if (preprocessed == null) return; // skip frame if preprocessing failed

        final embedding = faceService.generateEmbedding(preprocessed);
        if (embedding == null) return; // skip frame if embedding failed

        // Duplicate check on first pose only
        if (_currentPose == RegistrationPose.front) {
          final db           = DatabaseService.instance;
          final allEmployees = await db.getAllEmployees();
          final knownFaces   = allEmployees
              .where((e) => e.facialEmbedding.isNotEmpty && (widget.editEmployee == null || e.id != widget.editEmployee!.id))
              .map((e) => MapEntry(e.name, e.facialEmbedding))
              .toList();

          final duplicateName = FaceRecognitionService.checkDuplicateEmbedding(
              embedding, knownFaces);
          if (duplicateName != null) {
            final bool? continueReg = await _showDuplicateFaceWarning(duplicateName);
            if (continueReg != true) {
              _cameraController?.stopImageStream();
              if (mounted) {
                setState(() {
                  _step         = RegistrationStep.enterName;
                  _isCameraReady = false;
                  _capturedEmbeddings.clear();
                });
              }
              return;
            }
          }
        }

        _capturedEmbeddings.add(embedding);
        _moveToNextPose();
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
      RegistrationPose.left  => 'Slowly turn your head to the LEFT',
      RegistrationPose.right => 'Slowly turn your head to the RIGHT',
      RegistrationPose.up    => 'Tilt your head UPWARDS',
      RegistrationPose.blink => 'Now, BLINK your eyes',
      _                      => '',
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

      // Guard: non-admin MUST have captured embeddings and blinked
      if (!_isFirstAdmin &&
          !(widget.editEmployee?.isAdmin ?? false)) {
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
            _errorMessage = 'Liveness check failed (no blink detected). Please try again.';
          });
          return;
        }
      }

      final avgEmbedding = _capturedEmbeddings.isEmpty
          ? (widget.editEmployee?.facialEmbedding ?? List<double>.filled(128, 0.0))
          : _averageEmbeddings(_capturedEmbeddings);

      final name     = _nameController.text.trim();
      final email    = _emailController.text.trim();
      final age      = int.tryParse(_ageController.text.trim()) ?? 0;
      final position = _positionController.text.trim();
      final empId    = _empIdController.text.trim();

      if (widget.editEmployee != null) {
        // EDIT MODE
        final updated = Employee(
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
          username:        widget.editEmployee!.isAdmin ? _usernameController.text : null,
          password:        widget.editEmployee!.isAdmin ? _passwordController.text : null,
          isDeleted:       widget.editEmployee!.isDeleted,
        );
        await db.updateEmployee(updated);
        _syncProviders();

        if (mounted) {
          setState(() {
            _step         = RegistrationStep.success;
            _statusMessage = 'Profile updated successfully!';
          });
        }
      } else {
        // ENROLL MODE
        final bool isAdmin = _isFirstAdmin;

        await db.insertEmployee(
          Employee(
            name:            name,
            email:           email,
            age:             age,
            sex:             _selectedSex,
            position:        position,
            department:      _selectedDepartment,
            empId:           empId,
            isAdmin:         isAdmin,
            facialEmbedding: avgEmbedding,
            username:        isAdmin ? _usernameController.text.trim() : null,
            password:        isAdmin ? _passwordController.text.trim() : null,
          ),
        );

        _syncProviders();

        if (mounted) {
          setState(() {
            _step          = RegistrationStep.success;
            _statusMessage = isAdmin
                ? '$name registered as SYSTEM ADMIN!'
                : '$name has been registered! ID: $empId';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _step         = RegistrationStep.error;
          _errorMessage = 'Failed to save: $e';
        });
      }
    }
  }

  void _syncProviders() {
    ref.invalidate(employeesProvider);
    ref.invalidate(currentlyWorkingProvider);
    ref.invalidate(absentTodayProvider);
    ref.invalidate(attendanceLogsWithNamesProvider);
  }

  List<double> _averageEmbeddings(List<List<double>> embeddings) {
    if (embeddings.isEmpty) return List<double>.filled(128, 0.0);
    final len = embeddings.first.length;
    if (len == 0) return List<double>.filled(128, 0.0);
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
                        decoration: _buildInputDecoration(
                            'ID-XXX', Icons.badge_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            Row(
              children: [
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
              ],
            ),
            const SizedBox(height: 20),

            _buildFieldLabel('Company Position'),
            TextFormField(
              controller: _positionController,
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration(
                  'e.g. Software Engineer', Icons.work),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Position is required' : null,
            ),
            const SizedBox(height: 20),

            _buildFieldLabel('Department'),
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
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Username is required' : null,
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
                  if (v.length < 8) return 'Password must be at least 8 characters';
                  if (!v.contains(RegExp(r'[A-Z]'))) return 'Must contain an uppercase letter';
                  if (!v.contains(RegExp(r'[0-9]'))) return 'Must contain a number';
                  if (!v.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-]'))) return 'Must contain a special character';
                  return null;
                },
              ),
            ],

            const SizedBox(height: 48),
            const SizedBox(height: 48),

            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton.icon(
                icon: Icon(_isFirstAdmin || (widget.editEmployee?.isAdmin ?? false)
                    ? Icons.save_rounded
                    : Icons.camera_alt_outlined),
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
                  if (_formKey.currentState!.validate()) {
                    if (_isFirstAdmin ||
                        (widget.editEmployee?.isAdmin ?? false)) {
                      _saveEmployee();
                    } else {
                      final db        = DatabaseService.instance;
                      final employees = await db.getAllEmployees();

                      final String name  = _nameController.text.trim().toLowerCase();
                      final String empId = _empIdController.text.trim().toLowerCase();

                      final bool exists = employees.any((e) =>
                          (e.name.toLowerCase() == name ||
                              e.empId.toLowerCase() == empId) &&
                          e.id != widget.editEmployee?.id);

                      if (exists) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Employee with this Name or ID already exists!'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                        return;
                      }

                      setState(() {
                        _step        = RegistrationStep.scanFace;
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
          style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w500)),
    );
  }

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
  
  /// Maps the visual registration oval to the raw camera buffer indices.
  /// Synchronized with CameraScreen for identical recognition context.
  Rect _getOvalBufferRect(int bufferWidth, int bufferHeight) {
    const double nx = 0.5;
    const double ny = 0.45; // Match CameraScreen's center
    final double centerBx = (1.0 - ny) * bufferWidth;
    final double centerBy = nx * bufferHeight;
    final double cropSize = bufferHeight * 0.72;

    return Rect.fromCenter(
      center: Offset(centerBx, centerBy),
      width: cropSize,
      height: cropSize,
    );
  }

  // ─── Step 2: Face Scan Screen ─────────────────────────────────────────────

  Widget _buildFaceScan() {
    if (!_isCameraReady || _cameraController == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.teal));
    }

    final size  = MediaQuery.of(context).size;
    var scale   = size.aspectRatio * _cameraController!.value.aspectRatio;
    if (scale < 1) scale = 1 / scale;

    final progress = _capturedEmbeddings.length / 5.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
            scale: scale,
            child: Center(child: CameraPreview(_cameraController!))),

        Center(
          child: CustomPaint(
            size: Size(size.width, size.height),
            painter: _GuidedOvalPainter(
                pose: _currentPose, progress: progress),
          ),
        ),

        Positioned(
          top: 100,
          left: 0,
          right: 0,
          child: Center(child: _PoseGraphic(pose: _currentPose)),
        ),

        Positioned(
          bottom: 48,
          left: 24,
          right: 24,
          child: Column(
            children: [
              Text(
                _statusMessage,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value:            progress,
                backgroundColor:  Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                borderRadius:     BorderRadius.circular(4),
                minHeight:        8,
              ),
              const SizedBox(height: 8),
              Text(
                  'Step ${_capturedEmbeddings.length + 1} of 5',
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
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
              isSuccess
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
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
                          .pushNamedAndRemoveUntil('/', (route) => false);
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

  // ─── Duplicate Face Dialog ────────────────────────────────────────────────

  Future<bool?> _showDuplicateFaceWarning(String? matchedName) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Possible Duplicate Face',
            style: TextStyle(color: Colors.orangeAccent)),
        content: Text(
          'This face appears to match an already registered employee: $matchedName.\n\nAre you sure you want to proceed?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel registration',
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

  // ─── Main Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    String title = switch (_step) {
      RegistrationStep.enterName  => widget.editEmployee != null ? 'Update Profile' : 'Register Employee',
      RegistrationStep.scanFace   => widget.editEmployee != null ? 'Re-enroll Face' : 'Enroll Face',
      RegistrationStep.processing => widget.editEmployee != null ? 'Updating…' : 'Enrolling…',
      RegistrationStep.success    => 'Complete',
      RegistrationStep.error      => 'Failure',
    };

    Widget body = switch (_step) {
      RegistrationStep.enterName => _buildNameEntry(),
      RegistrationStep.scanFace  => _buildFaceScan(),
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
                    _step        = RegistrationStep.enterName;
                    _capturedEmbeddings.clear();
                    _currentPose  = RegistrationPose.front;
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
      RegistrationPose.left  => (Icons.arrow_back, const Offset(-40, 0)),
      RegistrationPose.right => (Icons.arrow_forward, const Offset(40, 0)),
      RegistrationPose.up    => (Icons.arrow_upward, const Offset(0, -40)),
      RegistrationPose.blink => (Icons.remove_red_eye_outlined, Offset.zero),
      _                      => (Icons.check, Offset.zero),
    };

    return TweenAnimationBuilder<Offset>(
      duration: const Duration(milliseconds: 400),
      curve:    Curves.elasticOut,
      tween:    Tween(begin: Offset.zero, end: offset),
      builder: (context, val, child) {
        return Transform.translate(
          offset: val,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
                color: Colors.teal.withAlpha(200), shape: BoxShape.circle),
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
    final cx    = size.width / 2;
    final cy    = size.height * 0.45; // Match Scanner's 0.45
    final ovalW = size.width * 0.65; // Unified width
    final ovalH = ovalW * 1.35;
    final rect  = Rect.fromCenter(
        center: Offset(cx, cy), width: ovalW, height: ovalH);

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addOval(rect),
      ),
      Paint()..color = Colors.black54,
    );

    final paint = Paint()
      ..color      = Colors.white24
      ..strokeWidth = 3
      ..style      = PaintingStyle.stroke;

    canvas.drawOval(rect, paint);

    final activePaint = Paint()
      ..color      = Colors.tealAccent
      ..strokeWidth = 6
      ..style      = PaintingStyle.stroke
      ..strokeCap  = StrokeCap.round;

    if (pose != RegistrationPose.done) {
      final sweep = 2 * 3.14159 * progress;
      canvas.drawArc(rect, -3.14159 / 2, sweep, false, activePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GuidedOvalPainter old) =>
      old.pose != pose || old.progress != progress;
}