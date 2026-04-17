import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database_service.dart';
import '../../attendance/providers/attendance_provider.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _totalPresentToday = 0;
  int _totalEmployees = 0;

  // Filters
  String _searchQuery = '';
  String _typeFilter = 'All'; // 'All', 'IN', 'OUT'
  DateTime? _dateFilter; // null means Today

  @override
  void initState() {
    super.initState();
    _calculateMetrics();
  }

  Future<void> _calculateMetrics() async {
    final db = DatabaseService.instance;
    final logsToday = await db.getAttendanceLogsWithNamesToday();
    final allEmployees = await db.getAllEmployees();
    
    // Total distinct employees who timed IN today
    final presentEmpIds = logsToday
        .where((l) => l['type'] == 'IN')
        .map((l) => l['employee_id'])
        .toSet();

    if (mounted) {
      setState(() {
        _totalPresentToday = presentEmpIds.length;
        _totalEmployees = allEmployees.length;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(attendanceLogsWithNamesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Attendance Logs', 
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).pushNamed('/employee_list'),
            icon: const Icon(Icons.people_outline, color: Colors.tealAccent),
            tooltip: 'View All Employee',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: Colors.tealAccent,
        backgroundColor: Colors.black87,
        onRefresh: () async {
          ref.invalidate(attendanceLogsWithNamesProvider);
          await _calculateMetrics();
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── Metrics & Filters Header ──────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            title: 'At Work Now',
                            value: _totalPresentToday.toString(),
                            icon: Icons.work_outline,
                            color: Colors.tealAccent,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _MetricCard(
                            title: 'People Registered',
                            value: _totalEmployees.toString(),
                            icon: Icons.badge_outlined,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Filter Bar
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        children: [
                          TextField(
                            onChanged: (v) => setState(() => _searchQuery = v),
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Search by name...',
                              hintStyle: const TextStyle(color: Colors.white38),
                              prefixIcon: const Icon(Icons.search, color: Colors.white38),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.black26,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              // Type Filter
                              Expanded(
                                child: SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(value: 'All', label: Text('All', style: TextStyle(fontSize: 12))),
                                    ButtonSegment(value: 'IN', label: Text('IN', style: TextStyle(fontSize: 12))),
                                    ButtonSegment(value: 'OUT', label: Text('OUT', style: TextStyle(fontSize: 12))),
                                  ],
                                  selected: {_typeFilter},
                                  onSelectionChanged: (set) => setState(() => _typeFilter = set.first),
                                  style: ButtonStyle(
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                                      if (states.contains(WidgetState.selected)) return Colors.teal;
                                      return Colors.transparent;
                                    }),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Date Filter
                              IconButton.filledTonal(
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: _dateFilter ?? DateTime.now(),
                                    firstDate: DateTime(2024),
                                    lastDate: DateTime.now(),
                                  );
                                  setState(() => _dateFilter = picked);
                                },
                                icon: Icon(_dateFilter == null ? Icons.today : Icons.event, size: 20),
                                style: IconButton.styleFrom(
                                  backgroundColor: _dateFilter == null ? Colors.white10 : Colors.teal.withAlpha(50),
                                  foregroundColor: _dateFilter == null ? Colors.white70 : Colors.tealAccent,
                                ),
                              ),
                              if (_dateFilter != null)
                                IconButton(
                                  onPressed: () => setState(() => _dateFilter = null),
                                  icon: const Icon(Icons.close, size: 18, color: Colors.white38),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Logs List ────────────────────────────────────────────────
            logsAsync.when(
              data: (logs) {
                // Apply manual filtering
                final filteredLogs = logs.where((log) {
                  final name = (log['employee_name'] as String? ?? 'Deleted Employee').toLowerCase();
                  if (_searchQuery.isNotEmpty && !name.contains(_searchQuery.toLowerCase())) return false;
                  
                  if (_typeFilter != 'All' && log['type'] != _typeFilter) return false;
                  
                  if (_dateFilter != null) {
                    final logDate = DateTime.parse(log['timestamp'] as String);
                    if (logDate.year != _dateFilter!.year ||
                        logDate.month != _dateFilter!.month ||
                        logDate.day != _dateFilter!.day) {
                      return false;
                    }
                  }
                  
                  return true;
                }).toList();

                if (filteredLogs.isEmpty) {
                  return const SliverFillRemaining(
                    child: Center(
                      child: Text('No matching logs found.', style: TextStyle(color: Colors.white54)),
                    ),
                  );
                }

                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _LogTile(logMap: filteredLogs[index]),
                      childCount: filteredLogs.length,
                    ),
                  ),
                );
              },
              loading: () => const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: Colors.teal))),
              error: (e, st) => SliverFillRemaining(child: Center(child: Text('Error: $e', style: const TextStyle(color: Colors.redAccent)))),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Metric Card ─────────────────────────────────────────────────────────────

class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(
                color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 13,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// ─── Log Tile ────────────────────────────────────────────────────────────────

class _LogTile extends StatelessWidget {
  final Map<String, dynamic> logMap;

  const _LogTile({required this.logMap});

  @override
  Widget build(BuildContext context) {
    final timestamp = logMap['timestamp'] as String;
    final dt = DateTime.parse(timestamp);
    final isToday = dt.day == DateTime.now().day && dt.month == DateTime.now().month;
    
    final dateStr = isToday 
        ? 'Today' 
        : DateFormat('MMM d, yyyy').format(dt);
    final timeStr = DateFormat('hh:mm a').format(dt);

    final type = logMap['type'] as String;
    final isIn = type == 'IN';
    final actionColor = isIn ? Colors.tealAccent : const Color(0xFFE05E5E);
    final icon = isIn ? Icons.login : Icons.logout;

    final name = logMap['employee_name'] as String? ?? 'Unknown';
    final empId = logMap['employee_code'] as String? ?? 'N/A';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Row(
        children: [
          // Action Type Column
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: actionColor.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: actionColor, size: 18),
          ),
          const SizedBox(width: 16),
          // Employee Details
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'ID: $empId',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          // Time Details
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeStr,
                  style: const TextStyle(color: Colors.tealAccent, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                Text(
                  dateStr,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

