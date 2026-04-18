import 'package:flutter/material.dart';
import '../../../core/database/database_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _db = DatabaseService.instance;
  bool _isLoading = true;
  
  TimeOfDay _workStart = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _workEnd = const TimeOfDay(hour: 17, minute: 0);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final startStr = await _db.getSetting('work_start', '08:00');
    final endStr = await _db.getSetting('work_end', '17:00');

    setState(() {
      _workStart = _parseTime(startStr);
      _workEnd = _parseTime(endStr);
      _isLoading = false;
    });
  }

  TimeOfDay _parseTime(String time) {
    final parts = time.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  String _formatTime(TimeOfDay time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _selectTime(BuildContext context, bool isStart) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _workStart : _workEnd,
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.tealAccent,
              onPrimary: Colors.black,
              surface: Color(0xFF161B22),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        if (isStart) {
          _workStart = picked;
        } else {
          _workEnd = picked;
        }
      });
      
      await _db.updateSetting(isStart ? 'work_start' : 'work_end', _formatTime(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('System Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.teal))
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _buildSectionTitle('Attendance Rules'),
                const SizedBox(height: 16),
                _buildTimeSettingTile(
                  title: 'Daily Check-In Time',
                  subtitle: 'Employees clocking in after this will be marked "Late"',
                  time: _workStart,
                  icon: Icons.login_rounded,
                  onTap: () => _selectTime(context, true),
                ),
                const SizedBox(height: 12),
                _buildTimeSettingTile(
                  title: 'Daily Check-Out Time',
                  subtitle: 'Employees clocking out before this will be marked "Early Out"',
                  time: _workEnd,
                  icon: Icons.logout_rounded,
                  onTap: () => _selectTime(context, false),
                ),
                const SizedBox(height: 40),
                _buildInfoCard(),
              ],
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: Colors.tealAccent,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildTimeSettingTile({
    required String title,
    required String subtitle,
    required TimeOfDay time,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.teal.withOpacity(0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: Colors.tealAccent),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 13)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                time.format(context),
                style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.2)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline_rounded, color: Colors.blueAccent),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              'Settings are saved automatically. These changes will apply to all future attendance logs.',
              style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
