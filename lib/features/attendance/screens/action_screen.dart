import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';
import '../../face_recognition/providers/face_recognition_provider.dart';
import '../providers/attendance_provider.dart';

class ActionScreen extends ConsumerStatefulWidget {
  /// The name of the recognized employee passed via route arguments.
  final String employeeName;

  const ActionScreen({super.key, required this.employeeName});

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
    final employees = await db.getAllEmployees();
    final match = employees.where((e) => e.name == widget.employeeName).firstOrNull;

    if (match != null) {
      final lastAttendance = await db.getLastAttendanceForEmployee(match.id!);
      if (mounted) {
        setState(() {
          _employee = match;
          _lastAction = lastAttendance?.type;
          _isLoading = false;
        });
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
      _showResultSnackBar(status.message!, success: true);
      // Reset liveness so we can recognise next person freshly
      ref.read(livenessServiceProvider).reset();
      ref.read(livenessStateProvider.notifier).set(
          // reset to waiting
          // ignore: invalid_use_of_internal_member
          ref.read(livenessStateProvider)); // refresh widget 
      // Go back to scanner after a short delay
      await Future.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).pop();
    } else {
      _showResultSnackBar(status.message ?? 'An error occurred.',
          success: false);
    }
  }

  void _showResultSnackBar(String message, {required bool success}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(success ? Icons.check_circle : Icons.error_outline,
                color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: success ? Colors.teal.shade700 : Colors.red.shade700,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final actionState = ref.watch(attendanceNotifierProvider);
    final isRecording = actionState.status == AttendanceActionStatus.loading;

    // Smart suggestion: if last action was IN, suggest OUT, and vice versa
    final suggestedType = _lastAction == 'IN' ? 'OUT' : 'IN';

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

                    // ── Back button ──────────────────────────────────────
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new,
                            color: Colors.white70),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // ── Avatar ───────────────────────────────────────────
                    ScaleTransition(
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
                            BoxShadow(
                              color: Colors.tealAccent.withAlpha(100),
                              blurRadius: 24,
                              spreadRadius: 4,
                            )
                          ],
                        ),
                        child: const Icon(Icons.person,
                            size: 60, color: Colors.white),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // ── Employee Name ─────────────────────────────────────
                    Text(
                      widget.employeeName,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.4,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 6),

                    // ── Status badge ──────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.tealAccent.withAlpha(26),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.tealAccent.withAlpha(80)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.verified_user,
                              color: Colors.tealAccent, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            'Identity Verified',
                            style: TextStyle(
                                color: Colors.tealAccent.shade200,
                                fontSize: 13,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // ── Current Time ──────────────────────────────────────
                    _LiveClock(),

                    const SizedBox(height: 12),

                    // ── Last action hint ──────────────────────────────────
                    if (_lastAction != null)
                      Text(
                        'Last recorded: Time $_lastAction  •  Suggested: Time $suggestedType',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),

                    const Spacer(),

                    // ── Time In / Time Out Buttons ────────────────────────
                    _AttendanceButton(
                      label: 'Time IN',
                      icon: Icons.login_rounded,
                      color: Colors.teal,
                      isSuggested: suggestedType == 'IN',
                      isLoading: isRecording,
                      onTap: isRecording ? null : () => _record('IN'),
                    ),

                    const SizedBox(height: 16),

                    _AttendanceButton(
                      label: 'Time OUT',
                      icon: Icons.logout_rounded,
                      color: const Color(0xFFE05E5E),
                      isSuggested: suggestedType == 'OUT',
                      isLoading: isRecording,
                      onTap: isRecording ? null : () => _record('OUT'),
                    ),

                    const SizedBox(height: 40),
                  ],
                ),
              ),
      ),
    );
  }
}

// ─── Live Clock Widget ───────────────────────────────────────────────────────

class _LiveClock extends StatefulWidget {
  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  late String _time;

  @override
  void initState() {
    super.initState();
    _updateTime();
    // refresh every second
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(_updateTime);
      return true;
    });
  }

  void _updateTime() {
    _time = DateFormat('hh:mm:ss a').format(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _time,
      style: const TextStyle(
        fontSize: 20,
        color: Colors.white54,
        fontWeight: FontWeight.w300,
        letterSpacing: 2,
      ),
    );
  }
}

// ─── Attendance Button ────────────────────────────────────────────────────────

class _AttendanceButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isSuggested;
  final bool isLoading;
  final VoidCallback? onTap;

  const _AttendanceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.isSuggested,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: double.infinity,
      height: 70,
      decoration: BoxDecoration(
        gradient: isSuggested
            ? LinearGradient(
                colors: [color, color.withAlpha(200)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              )
            : null,
        color: isSuggested ? null : Colors.white10,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isSuggested ? color : Colors.white12,
          width: isSuggested ? 1.5 : 1,
        ),
        boxShadow: isSuggested
            ? [
                BoxShadow(
                    color: color.withAlpha(80),
                    blurRadius: 18,
                    spreadRadius: 1)
              ]
            : [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child:
                      CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                )
              else
                Icon(icon, color: Colors.white, size: 26),
              const SizedBox(width: 14),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              if (isSuggested) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Suggested',
                      style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
