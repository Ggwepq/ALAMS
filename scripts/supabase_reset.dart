import 'package:supabase/supabase.dart';
import 'package:password_hash_plus/password_hash_plus.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

void main() async {
  // ===============================================
  // 📝 MASTER ADMIN CONFIGURATION
  // ===============================================
  const String rawPassword = 'admin123';

  final adminDetails = {
    'id': 1,
    'name': 'System Administrator',
    'emp_id': 'ADMIN-001',
    'username': 'admin',
    'password': '', // Will be filled with hash below
    'is_admin': 1,
    'is_deleted': 0,
    'age': 30,
    'sex': 'Other',
    'position': 'Lead Administrator',
    'department': 'General',
    'email': 'admin@alams.io',
    'facial_embedding': '',
  };
  // ===============================================

  print('🚀 Starting Master Supabase Reset (SECURE MODE)...');

  // 1. Generate Secure PBKDF2 Hash (Match App Logic)
  final salt = _randomBytes(16);
  final generator = PBKDF2();
  final hashBytes = generator.generateKey(
    rawPassword,
    base64.encode(salt),
    10000,
    32,
  );

  // App-Compatible Format: pbkdf2$<iterations>$<base64salt>$<base64hash>
  final secureHash =
      'pbkdf2\$10000\$${base64.encode(salt)}\$${base64.encode(hashBytes)}';
  adminDetails['password'] = secureHash;

  // 2. Map .env
  final env = <String, String>{};
  try {
    final file = File('.env');
    if (!file.existsSync()) {
      print('❌ Error: .env file not found.');
      return;
    }
    for (var line in file.readAsLinesSync()) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split('=');
      if (parts.length >= 2) {
        final key = parts[0].trim();
        final value = parts.sublist(1).join('=').trim();
        env[key] = value.replaceAll('"', '').replaceAll("'", "");
      }
    }
  } catch (e) {
    print('❌ Error reading .env: $e');
    return;
  }

  final url = env['SUPABASE_URL'];
  final key = env['SUPABASE_ANON_KEY'];
  if (url == null || key == null) return;

  final supabase = SupabaseClient(url, key);

  try {
    print('🧹 Deleting ALL Attendance Logs...');
    await supabase.from('attendance').delete().neq('id', -1);

    print('🧹 Deleting ALL Departments...');
    await supabase.from('departments').delete().neq('id', -1);

    print('🧹 Deleting ALL Employees (Total Wipe)...');
    await supabase.from('employees').delete().neq('id', -1);

    print('🌱 Seeding Master Admin with SECURE HASH...');
    // await supabase.from('employees').insert(adminDetails);

    print('🌱 Re-seeding System Settings...');
    await supabase.from('system_settings').upsert([
      {'key': 'work_start', 'value': '08:00'},
      {'key': 'work_end', 'value': '17:00'},
      {'key': 'grace_period', 'value': '60'},
      {'key': 'watermark_enabled', 'value': '1'},
    ]);

    print('✅ Master Reset & Secure Seeding Complete!');
    print('💡 Initial Login: admin / $rawPassword (stored as $secureHash)');

    exit(0);
  } catch (e) {
    print('❌ Reset Failed: $e');
    exit(1);
  }
}

List<int> _randomBytes(int length) {
  final rnd = Random.secure();
  return List<int>.generate(length, (_) => rnd.nextInt(256));
}
