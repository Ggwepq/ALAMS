import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/database/database_service.dart';
import '../../../core/models/employee.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  final Employee employee;

  const AttendanceHistoryScreen({super.key, required this.employee});

  @override
  State<AttendanceHistoryScreen> createState() => _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final logs = await DatabaseService.instance.getAttendanceLogsForEmployee(widget.employee.id!);
    if (mounted) {
      setState(() {
        _logs = logs;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: Text('${widget.employee.name}\'s History', 
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.teal))
          : Column(
              children: [
                _buildheaderInfo(),
                Expanded(
                  child: _logs.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _logs.length,
                          itemBuilder: (context, index) {
                            final log = _logs[index];
                            return _buildLogTile(log);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildheaderInfo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.employee.empId, 
              style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 13)),
          Text(widget.employee.position, 
              style: const TextStyle(color: Colors.white70, fontSize: 15)),
          const SizedBox(height: 8),
          Text('Total Records: ${_logs.length}', 
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildLogTile(Map<String, dynamic> log) {
    final type = log['type'] as String;
    final timestamp = DateTime.parse(log['timestamp'] as String);
    final dateStr = DateFormat('MMMM dd, yyyy').format(timestamp);
    final timeStr = DateFormat('hh:mm a').format(timestamp);

    final isTimeIn = type == 'IN';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (isTimeIn ? Colors.teal : Colors.redAccent).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isTimeIn ? Icons.login_rounded : Icons.logout_rounded,
              color: isTimeIn ? Colors.tealAccent : Colors.redAccent,
              size: 20,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isTimeIn ? 'TIME IN' : 'TIME OUT',
                  style: TextStyle(
                    color: isTimeIn ? Colors.tealAccent : Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(dateStr, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          Text(timeStr, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_toggle_off, size: 64, color: Colors.white10),
          const SizedBox(height: 16),
          const Text('No attendance records yet', style: TextStyle(color: Colors.white24)),
        ],
      ),
    );
  }
}
