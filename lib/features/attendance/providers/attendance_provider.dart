import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/attendance.dart';
import '../../../core/providers/database_provider.dart';

// ─── Attendance Log Providers ───────────────────────────────────────────────

final attendanceLogsProvider = FutureProvider<List<Attendance>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogs();
});

final attendanceLogsWithNamesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogsWithNames();
});

final attendanceLogsTodayProvider =
    FutureProvider<List<Attendance>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogsToday();
});

final attendanceLogsTodayWithNamesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogsWithNamesToday();
});

// ─── Attendance Actions Notifier ─────────────────────────────────────────────

/// State holding the result of a Time In / Time Out action.
enum AttendanceActionStatus { idle, loading, success, error }

class AttendanceActionState {
  final AttendanceActionStatus status;
  final String? message;

  const AttendanceActionState({
    this.status = AttendanceActionStatus.idle,
    this.message,
  });
}

class AttendanceNotifier extends Notifier<AttendanceActionState> {
  @override
  AttendanceActionState build() => const AttendanceActionState();

  Future<void> recordAttendance({
    required int employeeId,
    required String employeeName,
    required String type, // 'IN' or 'OUT'
  }) async {
    state = const AttendanceActionState(status: AttendanceActionStatus.loading);

    try {
      final db = ref.read(databaseServiceProvider);
      final timestamp = DateTime.now().toIso8601String();

      await db.insertAttendance(
        Attendance(
          employeeId: employeeId,
          timestamp: timestamp,
          type: type,
        ),
      );

      // Invalidate providers so logs refresh automatically
      ref.invalidate(attendanceLogsProvider);
      ref.invalidate(attendanceLogsTodayProvider);

      state = AttendanceActionState(
        status: AttendanceActionStatus.success,
        message:
            '$employeeName — Time $type recorded at ${_formatTime(timestamp)}',
      );
    } catch (e) {
      state = AttendanceActionState(
        status: AttendanceActionStatus.error,
        message: 'Failed to record attendance: $e',
      );
    }
  }

  void reset() => state = const AttendanceActionState();

  String _formatTime(String iso) {
    final dt = DateTime.parse(iso);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

final attendanceNotifierProvider =
    NotifierProvider<AttendanceNotifier, AttendanceActionState>(
  AttendanceNotifier.new,
);
