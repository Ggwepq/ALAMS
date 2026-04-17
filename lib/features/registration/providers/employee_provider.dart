import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';

final employeesProvider = FutureProvider<List<Employee>>((ref) async {
  return await DatabaseService.instance.getAllEmployees();
});
