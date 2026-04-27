import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';

import '../providers/employee_provider.dart';
import '../../attendance/providers/attendance_provider.dart';

class EmployeeListScreen extends ConsumerStatefulWidget {
  const EmployeeListScreen({super.key});

  @override
  ConsumerState<EmployeeListScreen> createState() => _EmployeeListScreenState();
}

class _EmployeeListScreenState extends ConsumerState<EmployeeListScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  String? _filterDept;
  String? _filterStatus;
  bool _isInit = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isInit) {
      final settings = ModalRoute.of(context)?.settings;
      if (settings?.arguments is Map<String, dynamic>) {
        final args = settings!.arguments as Map<String, dynamic>;
        if (args.containsKey('department')) {
          _filterDept = args['department'];
          debugPrint('[EmployeeList] Filtering by Department: $_filterDept');
        }
        if (args.containsKey('status')) {
          _filterStatus = args['status'];
          debugPrint('[EmployeeList] Filtering by Status: $_filterStatus');
        }
      }
      _isInit = false;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[EmployeeList] Building with status=$_filterStatus dept=$_filterDept query=$_searchQuery');
    
    // Always watch the base employee list
    final employeesAsync = ref.watch(employeesProvider);
    // Also watch today's logs to calculate "Working" vs "Absent" locally
    final logsTodayAsync = ref.watch(attendanceLogsTodayProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          _filterStatus == 'working' 
            ? 'Currently At Work' 
            : _filterStatus == 'absent'
              ? 'Absent Today'
              : _filterDept == null ? 'Registered Persons' : '$_filterDept Personnel',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_filterDept != null || _filterStatus != null)
            IconButton(
              icon: const Icon(Icons.filter_list_off),
              onPressed: () => setState(() {
                _filterDept = null;
                _filterStatus = null;
              }),
              tooltip: 'Clear Filters',
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search by name...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                suffixIcon: _searchQuery.isNotEmpty 
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(employeesProvider);
                ref.invalidate(attendanceLogsTodayProvider);
              },
              color: Colors.tealAccent,
              child: employeesAsync.when(
                data: (allEmployees) {
                  return logsTodayAsync.when(
                    data: (logs) {
                      // 1. Calculate Status-based IDs
                      final Set<int> workingIds = {};
                      final Set<int> timedInTodayIds = {};

                      // Group logs by employee to find their LATEST action today
                      final Map<int, Map<String, dynamic>> latestLogs = {};
                      for (final log in logs) {
                        final empId = log['employee_id'] as int;
                        final timestamp = log['timestamp'] as String;
                        if (!latestLogs.containsKey(empId) || 
                            timestamp.compareTo(latestLogs[empId]!['timestamp']) > 0) {
                          latestLogs[empId] = log;
                        }
                        timedInTodayIds.add(empId);
                      }

                      for (final entry in latestLogs.entries) {
                        if (entry.value['type'] == 'IN') {
                          workingIds.add(entry.key);
                        }
                      }

                      // 2. Perform Filtering
                      final filtered = allEmployees.where((e) {
                        // Name Filter
                        final matchesName = e.name.toLowerCase().contains(_searchQuery.toLowerCase());
                        
                        // Dept Filter
                        final matchesDept = _filterDept == null || e.department == _filterDept;
                        
                        // Status Filter
                        bool matchesStatus = true;
                        if (_filterStatus == 'working') {
                          matchesStatus = workingIds.contains(e.id);
                        } else if (_filterStatus == 'absent') {
                          matchesStatus = !timedInTodayIds.contains(e.id);
                        }

                        return matchesName && matchesDept && matchesStatus;
                      }).toList();

                      if (filtered.isEmpty) {
                        return ListView(
                          children: [
                            SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                            Center(
                              child: Text(
                                _filterStatus == 'absent' 
                                  ? 'No one is absent yet.' 
                                  : 'No matching persons found.',
                                style: const TextStyle(color: Colors.white54)),
                            ),
                          ],
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final employee = filtered[index];
                          return _EmployeeTile(employee: employee);
                        },
                      );
                    },
                    loading: () => const Center(child: CircularProgressIndicator(color: Colors.teal)),
                    error: (e, st) => Center(child: Text('Error loading logs: $e')),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator(color: Colors.teal)),
                error: (e, st) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.redAccent))),
              ),
            ),
          ),
        ],
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
              ref.invalidate(currentlyWorkingProvider);
              ref.invalidate(absentTodayProvider);
              ref.invalidate(attendanceLogsTodayProvider);
              
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
