import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';
import '../../face_recognition/providers/face_recognition_provider.dart';
import '../providers/attendance_provider.dart';

class ActionScreen extends ConsumerStatefulWidget {
  /// The recognized employee passed via route arguments.
  final Employee employee;
  final String? presetAction; // 'IN' or 'OUT'

  const ActionScreen({
    super.key, 
    required this.employee,
    this.presetAction,
  });

  @override
  ConsumerState<ActionScreen> createState() => _ActionScreenState();
}

class _ActionScreenState extends ConsumerState<ActionScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  Employee? _employee;
  String? _lastAction; // 'IN' or 'OUT' — to pre-highlight the suggested action
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation =
        Tween<double>(begin: 0.97, end: 1.03).animate(_pulseController);

    _loadEmployeeData();
  }

  Future<void> _loadEmployeeData() async {
    final db = DatabaseService.instance;
    _employee = widget.employee;
    
    if (_employee != null) {
      final lastAttendance = await db.getLastAttendanceForEmployee(_employee!.id!);
      if (mounted) {
        setState(() {
          _lastAction = lastAttendance?.type;
          _isLoading = false;
        });
        
        // AUTO-RECORD LOGIC
        final autoType = (_lastAction == 'IN') ? 'OUT' : 'IN';
        _record(autoType);
      }
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // ─── Record Attendance ───────────────────────────────────────────────────

  Future<void> _record(String type) async {
    if (_employee == null) return;

    await ref.read(attendanceNotifierProvider.notifier).recordAttendance(
          employeeId: _employee!.id!,
          employeeName: _employee!.name,
          type: type,
        );

    final status = ref.read(attendanceNotifierProvider);
    if (!mounted) return;

    if (status.status == AttendanceActionStatus.success) {
      // Reset liveness so we can recognise next person freshly
      ref.read(livenessServiceProvider).reset();
      
      // Go back to scanner after a short delay
      await Future.delayed(const Duration(milliseconds: 2500));
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final actionState = ref.watch(attendanceNotifierProvider);
    final isRecording = actionState.status == AttendanceActionStatus.loading;
    final isSuccess = actionState.status == AttendanceActionStatus.success;
    final isError = actionState.status == AttendanceActionStatus.error;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.teal))
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 32),
                    
                    if (!isRecording && !isSuccess && !isError)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),

                    const SizedBox(height: 12),

                    // ── Status Icon / Avatar ────────────────────────────
                    _buildStatusIndicator(isRecording, isSuccess, isError),

                    const SizedBox(height: 32),

                    // ── Employee Name ─────────────────────────────────────
                    Text(
                      widget.employee.name,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 8),

                    // ── Employee Brief Profile ───────────────────────────
                    Text(
                      '${widget.employee.position}  •  ${widget.employee.department}',
                      style: const TextStyle(color: Colors.tealAccent, fontSize: 13, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Employee ID: ${widget.employee.empId}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 48),

                    // ── Action Message ────────────────────────────────────
                    if (isRecording)
                      const _StatusText(text: 'SECURELY RECORDING LOG...', color: Colors.white38)
                    else if (isSuccess)
                      Column(
                        children: [
                          const _StatusText(text: 'SUCCESSFULLY RECORDED', color: Colors.tealAccent),
                          const SizedBox(height: 24),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                            decoration: BoxDecoration(
                              color: Colors.teal.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.teal.withOpacity(0.3)),
                            ),
                            child: Text(
                              'LOG TYPE: ${_lastAction == 'IN' ? 'TIME OUT' : 'TIME IN'}',
                              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1),
                            ),
                          ),
                        ],
                      )
                    else if (isError)
                      _StatusText(text: actionState.message ?? 'ERROR RECORDING LOG', color: Colors.redAccent),

                    const Spacer(),
                    
                    if (isSuccess)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 40),
                        child: Text(
                          'Returning to home screen...',
                          style: TextStyle(color: Colors.white10, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildStatusIndicator(bool loading, bool success, bool error) {
    if (loading) {
      return Container(
        padding: const EdgeInsets.all(40),
        child: const CircularProgressIndicator(color: Colors.teal, strokeWidth: 3),
      );
    }

    if (success) {
      return ScaleTransition(
        scale: _pulseAnimation,
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.teal.withOpacity(0.1),
            border: Border.all(color: Colors.tealAccent, width: 2),
            boxShadow: [
              BoxShadow(color: Colors.tealAccent.withOpacity(0.2), blurRadius: 20, spreadRadius: 5),
            ],
          ),
          child: const Icon(Icons.check_circle_rounded, size: 80, color: Colors.tealAccent),
        ),
      );
    }

    if (error) {
      return Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.red.withOpacity(0.1),
          border: Border.all(color: Colors.redAccent, width: 2),
        ),
        child: const Icon(Icons.error_outline_rounded, size: 80, color: Colors.redAccent),
      );
    }

    return ScaleTransition(
      scale: _pulseAnimation,
      child: Container(
        width: 110,
        height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [Colors.teal, Colors.tealAccent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(color: Colors.tealAccent.withAlpha(100), blurRadius: 24, spreadRadius: 4)
          ],
        ),
        child: const Icon(Icons.person, size: 60, color: Colors.white),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2),
      textAlign: TextAlign.center,
    );
  }
}
