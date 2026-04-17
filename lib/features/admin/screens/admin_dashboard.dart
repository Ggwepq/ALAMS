import 'package:flutter/material.dart';
import '../../../core/database/database_service.dart';

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        title: const Text('Admin Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 32),
            _buildQuickActions(context),
            const SizedBox(height: 32),
            const Text('System Management', 
                style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _buildMenuTile(
              context,
              title: 'Employee Directory',
              subtitle: 'Manage and delete registered faces',
              icon: Icons.people_alt_outlined,
              color: Colors.blueAccent,
              route: '/employee_list',
            ),
            _buildMenuTile(
              context,
              title: 'Attendance Reports',
              subtitle: 'View and filter all system logs',
              icon: Icons.bar_chart_rounded,
              color: Colors.purpleAccent,
              route: '/reports',
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
                    Text('Enroll New Person', 
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
            final employees = await db.getAllEmployees();
            final admin = employees.firstWhere((e) => e.isAdmin);
            if (context.mounted) {
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
                    Text('Edit My Profile', 
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

  Widget _buildMenuTile(BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required String route,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        onTap: () => Navigator.pushNamed(context, route),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        tileColor: Colors.white.withOpacity(0.03),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
      ),
    );
  }
}
