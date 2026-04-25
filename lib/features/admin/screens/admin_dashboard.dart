import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_service.dart';
import '../../attendance/providers/attendance_provider.dart';
import '../../registration/providers/employee_provider.dart';

class AdminDashboard extends ConsumerWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workingCount = ref.watch(currentlyWorkingProvider).when(data: (d) => d.length, loading: () => 0, error: (_, __) => 0);
    final absentCount = ref.watch(absentTodayProvider).when(data: (d) => d.length, loading: () => 0, error: (_, __) => 0);
    final totalCount = ref.watch(employeesProvider).when(data: (d) => d.length, loading: () => 0, error: (_, __) => 0);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('Admin Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 24),
            
            // Insight Cards Row
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                   _InsightCard(
                    label: 'At Work',
                    value: workingCount.toString(),
                    icon: Icons.check_circle_rounded,
                    color: Colors.tealAccent,
                  ),
                  const SizedBox(width: 12),
                   _InsightCard(
                    label: 'Absent',
                    value: absentCount.toString(),
                    icon: Icons.cancel_rounded,
                    color: const Color(0xFFE05E5E),
                  ),
                  const SizedBox(width: 12),
                  _InsightCard(
                    label: 'Total Personnel',
                    value: totalCount.toString(),
                    icon: Icons.people_alt_rounded,
                    color: Colors.blueAccent,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),
            _buildQuickActions(context),
            const SizedBox(height: 32),
            const Text('Management Dashboard', 
                style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _buildMenuTile(
              context,
              title: 'View All Employee',
              subtitle: 'Manage faces and profiles',
              icon: Icons.people_alt_outlined,
              color: Colors.blueAccent,
              route: '/employee_list',
            ),
            _buildMenuTile(
              context,
              title: 'View Attendance Logs',
              subtitle: 'Check time ins and outs',
              icon: Icons.bar_chart_rounded,
              color: Colors.purpleAccent,
              route: '/reports',
            ),
            _buildMenuTile(
              context,
              title: 'Manage Departments',
              subtitle: 'Add or remove organizations',
              icon: Icons.business_rounded,
              color: Colors.orangeAccent,
              route: '/departments',
            ),
            _buildMenuTile(
              context,
              title: 'System Settings',
              subtitle: 'Set work hours & rules',
              icon: Icons.settings_rounded,
              color: Colors.grey,
              route: '/settings',
            ),
            const SizedBox(height: 40),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.logout, color: Colors.white38),
                label: const Text('Exit Admin Mode', style: TextStyle(color: Colors.white38)),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.teal.withOpacity(0.2), Colors.teal.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.teal.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: Colors.teal,
            child: const Icon(Icons.admin_panel_settings, color: Colors.white, size: 30),
          ),
          const SizedBox(width: 16),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome, Admin', 
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              Text('ALAMS Monitoring Active', 
                  style: TextStyle(color: Colors.tealAccent, fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Quick Actions', 
            style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        InkWell(
          onTap: () => Navigator.pushNamed(context, '/register'),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.teal,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Colors.teal.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4)),
              ],
            ),
            child: const Row(
              children: [
                Icon(Icons.person_add_alt_1, color: Colors.white, size: 32),
                SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Add Employee', 
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Start the face registration flow', 
                        style: TextStyle(color: Colors.white70, fontSize: 14)),
                  ],
                ),
                Spacer(),
                Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 16),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Edit My Profile Button
        InkWell(
          onTap: () async {
            final db = DatabaseService.instance;
            final admin = await db.getAdmin();
            if (context.mounted && admin != null) {
              Navigator.pushNamed(context, '/register', arguments: admin);
            }
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white10),
            ),
            child: const Row(
              children: [
                Icon(Icons.manage_accounts_outlined, color: Colors.tealAccent, size: 28),
                SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Edit Admin Profile', 
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('Update credentials or re-scan face', 
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
                Spacer(),
                Icon(Icons.chevron_right, color: Colors.white24, size: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuTile(BuildContext context,
      {required String title,
      required String subtitle,
      required IconData icon,
      required Color color,
      required String route}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: color.withOpacity(0.1), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 24),
        ),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
        subtitle:
            Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 13)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
        onTap: () => Navigator.of(context).pushNamed(route),
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _InsightCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
