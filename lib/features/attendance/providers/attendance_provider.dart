import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/attendance.dart';
import '../../../core/models/employee.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/sync_refresh_provider.dart';

// ─── Attendance Log Providers ────────────────────────────────────────────────

final attendanceLogsProvider = FutureProvider<List<Attendance>>((ref) async {
  ref.watch(syncRefreshCountProvider);
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogs();
});

final attendanceLogsWithNamesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(syncRefreshCountProvider);
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogsWithNames();
});

final attendanceLogsTodayProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(syncRefreshCountProvider);
  final db = ref.watch(databaseServiceProvider);
  return db.getAttendanceLogsWithNamesToday();
});

final currentlyWorkingProvider = FutureProvider<List<Employee>>((ref) async {
  ref.watch(syncRefreshCountProvider);
  final db = ref.watch(databaseServiceProvider);
  return db.getCurrentlyAtWork();
});

final absentTodayProvider = FutureProvider<List<Employee>>((ref) async {
  ref.watch(syncRefreshCountProvider);
  final db = ref.watch(databaseServiceProvider);
  return db.getAbsentToday();
});

// ─── Attendance Actions Notifier ─────────────────────────────────────────────

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
    required String type,
  }) async {
    state = const AttendanceActionState(status: AttendanceActionStatus.loading);

    try {
      final db        = ref.read(databaseServiceProvider);
      final timestamp = DateTime.now().toIso8601String();

      final statusText = await db.insertAttendance(
        Attendance(
          employeeId: employeeId,
          timestamp:  timestamp,
          type:       type,
        ),
      );

      // Invalidate so local device refreshes immediately without
      // waiting for the Supabase real-time bounce-back
      ref.invalidate(attendanceLogsProvider);
      ref.invalidate(attendanceLogsWithNamesProvider);
      ref.invalidate(attendanceLogsTodayProvider);
      ref.invalidate(currentlyWorkingProvider);
      ref.invalidate(absentTodayProvider);

      state = AttendanceActionState(
        status:  AttendanceActionStatus.success,
        message: statusText,
      );
    } catch (e) {
      state = AttendanceActionState(
        status:  AttendanceActionStatus.error,
        message: 'Failed to record attendance: $e',
      );
    }
  }

  void reset() => state = const AttendanceActionState();
}

final attendanceNotifierProvider =
    NotifierProvider<AttendanceNotifier, AttendanceActionState>(
  AttendanceNotifier.new,
);