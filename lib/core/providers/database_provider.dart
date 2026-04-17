import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_service.dart';
import '../models/employee.dart';
import '../models/attendance.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService.instance;
});

final employeesProvider = FutureProvider<List<Employee>>((ref) async {
  final dbService = ref.watch(databaseServiceProvider);
  return dbService.getAllEmployees();
});

final attendanceLogsProvider = FutureProvider<List<Attendance>>((ref) async {
  final dbService = ref.watch(databaseServiceProvider);
  return dbService.getAttendanceLogs();
});
