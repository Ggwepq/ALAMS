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
  int _totalLogsToday = 0;
  int _totalEmployees = 0;

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
        _totalLogsToday = logsToday.length;
        _totalEmployees = allEmployees.length;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch the logs with names
    final logsAsync = ref.watch(attendanceLogsWithNamesProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Attendance Reports', 
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
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
            // Metrics Header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            title: 'Present Today',
                            value: _totalPresentToday.toString(),
                            icon: Icons.people_alt,
                            color: Colors.tealAccent,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _MetricCard(
                            title: 'Registered',
                            value: _totalEmployees.toString(),
                            icon: Icons.badge,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _MetricCard(
                      title: 'Total Scans (Today)',
                      value: _totalLogsToday.toString(),
                      icon: Icons.history,
                      color: Colors.blueAccent,
                      fullWidth: true,
                    ),
                  ],
                ),
              ),
            ),

            // Section Title
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text('All Logs', style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
              ),
            ),

            // List
            logsAsync.when(
              data: (logs) {
                if (logs.isEmpty) {
                  return const SliverFillRemaining(
                    child: Center(
                      child: Text('No attendance logs yet.', style: TextStyle(color: Colors.white54)),
                    ),
                  );
                }

                return SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final logMap = logs[index];
                        return _LogTile(logMap: logMap);
                      },
                      childCount: logs.length,
                    ),
                  ),
                );
              },
              loading: () => const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator(color: Colors.teal)),
              ),
              error: (e, st) => SliverFillRemaining(
                child: Center(child: Text('Error: $e', style: const TextStyle(color: Colors.redAccent))),
              ),
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
  final bool fullWidth;

  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: fullWidth ? double.infinity : null,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 28),
              if (fullWidth) ...[
                const Spacer(),
                Text(
                  value,
                  style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          if (!fullWidth)
            Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
            ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500),
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

    final name = logMap['employee_name'] as String? ?? 'Deleted Employee';

    return Container(
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
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: actionColor.withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: actionColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '$dateStr at $timeStr',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
          Text(
            type,
            style: TextStyle(
              color: actionColor,
              fontWeight: FontWeight.bold,
              fontSize: 16,
              letterSpacing: 1,
            ),
          )
        ],
      ),
    );
  }
}

