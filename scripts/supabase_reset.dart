import 'package:supabase/supabase.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// ---------------------------------------------------------------------------
/// 🔒 ALAMS CRYPTO ENGINE (Mirrored from CryptoUtils.dart)
/// ---------------------------------------------------------------------------
class CryptoEngine {
  static const int _iterations = 10000;
  static const int _saltBytes = 16;
  static const int _hashBytes = 32;

  static String hashPassword(String password) {
    final salt = _randomBytes(_saltBytes);
    final hash = _pbkdf2(utf8.encode(password), salt, _iterations, _hashBytes);
    return 'pbkdf2\$$_iterations\$${base64.encode(salt)}\$${base64.encode(hash)}';
  }

  static Uint8List _randomBytes(int count) {
    final rng = Random.secure();
    final bytes = Uint8List(count);
    for (int i = 0; i < count; i++) bytes[i] = rng.nextInt(256);
    return bytes;
  }

  static Uint8List _pbkdf2(List<int> password, List<int> salt, int iterations, int dkLen) {
    const hLen = 32;
    final blocks = (dkLen / hLen).ceil();
    final dk = Uint8List(blocks * hLen);
    for (int i = 1; i <= blocks; i++) {
        final saltBlock = Uint8List(salt.length + 4)..setAll(0, salt);
        saltBlock[salt.length] = (i >> 24) & 0xFF;
        saltBlock[salt.length + 1] = (i >> 16) & 0xFF;
        saltBlock[salt.length + 2] = (i >> 8) & 0xFF;
        saltBlock[salt.length + 3] = i & 0xFF;
        var u = _hmacSha256(password, saltBlock);
        final block = Uint8List.fromList(u);
        for (int j = 1; j < iterations; j++) {
            u = _hmacSha256(password, u);
            for (int k = 0; k < hLen; k++) block[k] ^= u[k];
        }
        dk.setAll((i - 1) * hLen, block);
    }
    return dk.sublist(0, dkLen);
  }

  static List<int> _hmacSha256(List<int> key, List<int> message) {
    const blockSize = 64;
    var k = key.length > blockSize ? _sha256(key) : List<int>.from(key);
    while (k.length < blockSize) k.add(0);
    final iPad = List<int>.generate(blockSize, (i) => k[i] ^ 0x36);
    final oPad = List<int>.generate(blockSize, (i) => k[i] ^ 0x5C);
    final inner = _sha256([...iPad, ...message]);
    return _sha256([...oPad, ...inner]);
  }

  static List<int> _sha256(List<int> message) {
    var h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const k = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    final bits = message.length * 8;
    final msg = List<int>.from(message)..add(0x80);
    while (msg.length % 64 != 56) msg.add(0);
    for (int i = 7; i >= 0; i--) msg.add((bits >> (i * 8)) & 0xFF);
    for (int i = 0; i < msg.length; i += 64) {
        final w = List<int>.filled(64, 0);
        for (int j = 0; j < 16; j++) w[j] = (msg[i+j*4]<<24) | (msg[i+j*4+1]<<16) | (msg[i+j*4+2]<<8) | (msg[i+j*4+3]);
        for (int j = 16; j < 64; j++) {
            final s0 = ((w[j-15]>>>7)|(w[j-15]<<25)) ^ ((w[j-15]>>>18)|(w[j-15]<<14)) ^ (w[j-15]>>>3);
            final s1 = ((w[j-2]>>>17)|(w[j-2]<<15)) ^ ((w[j-2]>>>19)|(w[j-2]<<13)) ^ (w[j-2]>>>10);
            w[j] = (w[j-16] + s0 + w[j-7] + s1) & 0xFFFFFFFF;
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int j = 0; j < 64; j++) {
            final S1 = ((e>>>6)|(e<<26)) ^ ((e>>>11)|(e<<21)) ^ ((e>>>25)|(e<<7));
            final ch = (e & f) ^ (~e & g);
            final t1 = (hh + S1 + ch + k[j] + w[j]) & 0xFFFFFFFF;
            final S0 = ((a>>>2)|(a<<30)) ^ ((a>>>13)|(a<<19)) ^ ((a>>>22)|(a<<10));
            final maj = (a & b) ^ (a & c) ^ (b & c);
            final t2 = (S0 + maj) & 0xFFFFFFFF;
            hh = g; g = f; f = e; e = (d + t1) & 0xFFFFFFFF; d = c; c = b; b = a; a = (t1 + t2) & 0xFFFFFFFF;
        }
        h[0]=(h[0]+a)&0xFFFFFFFF; h[1]=(h[1]+b)&0xFFFFFFFF; h[2]=(h[2]+c)&0xFFFFFFFF; h[3]=(h[3]+d)&0xFFFFFFFF;
        h[4]=(h[4]+e)&0xFFFFFFFF; h[5]=(h[5]+f)&0xFFFFFFFF; h[6]=(h[6]+g)&0xFFFFFFFF; h[7]=(h[7]+hh)&0xFFFFFFFF;
    }
    final result = <int>[];
    for (final word in h) result.addAll([(word>>24)&0xFF, (word>>16)&0xFF, (word>>8)&0xFF, word&0xFF]);
    return result;
  }
}

void main() async {
  const String rawPassword = 'Admin1234.';
  const String username    = 'admin';

  final adminDetails = {
    'id': 1,
    'name': 'System Administrator',
    'emp_id': 'ADMIN-001',
    'username': username,
    'password': CryptoEngine.hashPassword(rawPassword),
    'is_admin': 1,
    'is_deleted': 0,
    'age': 0,
    'sex': 'Other',
    'position': 'Admin',
    'department': 'General',
    'email': 'admin@alams.com',
    'facial_embedding': '',
  };

  print('🚀 Starting Master Supabase Reset (SECURE MODE)...');

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

    print('🌱 Seeding Master Admin with APP-COMPATIBLE HASH...');
    await supabase.from('employees').insert(adminDetails);

    print('🌱 Re-seeding System Settings...');
    await supabase.from('system_settings').upsert([
      {'key': 'work_start', 'value': '08:00'},
      {'key': 'work_end', 'value': '17:00'},
      {'key': 'grace_period', 'value': '60'},
      {'key': 'watermark_enabled', 'value': '1'},
    ]);

    print('✅ Master Reset & Secure Seeding Complete!');
    print('💡 Initial Login: $username / $rawPassword');

    exit(0);
  } catch (e) {
    print('❌ Reset Failed: $e');
    exit(1);
  }
}
