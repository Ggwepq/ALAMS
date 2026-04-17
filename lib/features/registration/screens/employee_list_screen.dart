import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';

import '../providers/employee_provider.dart';

class EmployeeListScreen extends ConsumerWidget {
  const EmployeeListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employeesAsync = ref.watch(employeesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Registered Persons',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: employeesAsync.when(
        data: (employees) {
          if (employees.isEmpty) {
            return const Center(
              child: Text('No persons registered yet.',
                  style: TextStyle(color: Colors.white54)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: employees.length,
            itemBuilder: (context, index) {
              final employee = employees[index];
              return _EmployeeTile(employee: employee);
            },
          );
        },
        loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.teal)),
        error: (e, st) => Center(
            child: Text('Error: $e',
                style: const TextStyle(color: Colors.redAccent))),
      ),
    );
  }
}

class _EmployeeTile extends ConsumerWidget {
  final Employee employee;
  const _EmployeeTile({required this.employee});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/user_history', arguments: employee),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(20)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.tealAccent.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person, color: Colors.tealAccent, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    employee.name,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${employee.position} • ${employee.empId}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Color(0xFFE05E5E)),
              onPressed: () => _confirmDelete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Delete Registered Person?',
            style: TextStyle(color: Colors.white)),
        content: Text(
            'Are you sure you want to remove ${employee.name}? Their attendance history will be preserved as "Deleted Employee".',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              await DatabaseService.instance.deleteEmployee(employee.id!);
              ref.invalidate(employeesProvider);
              // Also invalidate logs since they might now show "Deleted Employee"
              // We'll need to invalidate the name-joined logs
              // (Assuming those providers are in registration_provider.dart or similar)
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${employee.name} removed.')),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
