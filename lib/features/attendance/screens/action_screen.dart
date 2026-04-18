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
      // WE REMOVE THE AUTO-POP HERE TO STAY ON DASHBOARD
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
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // ── Status Icon / Avatar ────────────────────────────
                      _buildStatusIndicator(isRecording, isSuccess, isError),

                      const SizedBox(height: 32),

                      // ── Greeting ────────────────────────────────────────
                      if (isSuccess)
                        Text(
                          _getGreeting(),
                          style: const TextStyle(color: Colors.tealAccent, fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 1),
                        ),

                      const SizedBox(height: 12),

                      // ── Employee Name ─────────────────────────────────────
                      Text(
                        _employee?.name ?? 'Employee',
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 12),

                      // ── Employee Details Card ───────────────────────────
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          children: [
                            _buildInfoRow(Icons.badge_outlined, 'ID', widget.employee.empId),
                            const Divider(color: Colors.white10, height: 24),
                            _buildInfoRow(Icons.business_rounded, 'Dept', widget.employee.department),
                            const Divider(color: Colors.white10, height: 24),
                            _buildInfoRow(Icons.email_outlined, 'Email', widget.employee.email.isEmpty ? 'Not set' : widget.employee.email),
                          ],
                        ),
                      ),

                      const SizedBox(height: 48),

                      // ── Action Result ────────────────────────────────────
                      if (isRecording)
                        const _StatusText(text: 'RECORDING LOG...', color: Colors.white38)
                      else if (isSuccess)
                        _buildSuccessModule()
                      else if (isError)
                        _StatusText(text: actionState.message ?? 'ERROR RECORDING LOG', color: Colors.redAccent),

                      const SizedBox(height: 64),

                      // ── Dashboard Actions ────────────────────────────────
                      if (isSuccess || isError) ...[
                        SizedBox(
                          width: double.infinity,
                          height: 58,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.history_rounded),
                            label: const Text('View My Attendance History', style: TextStyle(fontWeight: FontWeight.bold)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.05),
                              foregroundColor: Colors.white70,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              side: const BorderSide(color: Colors.white10),
                            ),
                            onPressed: () => Navigator.pushNamed(context, '/user_history', arguments: widget.employee),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 58,
                          child: ElevatedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            child: const Text('Done / Back to Home', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'GOOD MORNING';
    if (hour < 17) return 'GOOD AFTERNOON';
    return 'GOOD EVENING';
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.tealAccent.withOpacity(0.5), size: 18),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 13)),
        const Spacer(),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildSuccessModule() {
    final actionState = ref.watch(attendanceNotifierProvider);
    final status = actionState.message ?? 'Normal';
    final now = DateTime.now();
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    
    // Color coding based on status
    final bool isWarning = status == 'Late' || status == 'Early Out';
    final Color statusColor = isWarning ? Colors.orangeAccent : Colors.tealAccent;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: statusColor.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(color: statusColor.withOpacity(0.05), blurRadius: 20, spreadRadius: 5),
            ],
          ),
          child: Column(
            children: [
              Text(
                'LOGGED ${_lastAction == 'IN' ? 'OUT' : 'IN'}',
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 2),
              ),
              const SizedBox(height: 8),
              Text(
                status.toUpperCase(),
                style: TextStyle(color: statusColor, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 1),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.access_time_rounded, color: Colors.white38, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'Recorded at $timeStr',
                    style: const TextStyle(color: Colors.white38, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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
