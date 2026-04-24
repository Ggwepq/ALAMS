import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';
import '../../../core/providers/sync_refresh_provider.dart';

final employeesProvider = FutureProvider<List<Employee>>((ref) async {
  // Re-runs automatically whenever SyncService triggers a refresh
  ref.watch(syncRefreshCountProvider);
  return await DatabaseService.instance.getAllEmployees();
});