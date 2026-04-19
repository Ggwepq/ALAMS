import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

/// Cryptographic utilities for ALAMS.
///
/// Provides PBKDF2-SHA256 password hashing with random salts — no external
/// packages required beyond Dart's built-in `dart:convert` and `dart:typed_data`.
///
/// Format stored in DB:  "pbkdf2$<iterations>$<base64salt>$<base64hash>"
class CryptoUtils {
  static const int _iterations = 10000; // Reduced from 100k for mobile snappiness
  static const int _saltBytes  = 16;
  static const int _hashBytes  = 32;

  // ─── Public API (Async/Modern) ─────────────────────────────────────────────

  /// Asynchronously hash [password] using a background Isolate.
  /// Prevents UI hanging during the 100k iteration calculation.
  static Future<String> hashPasswordAsync(String password) async {
    return await Isolate.run(() => hashPassword(password));
  }

  /// Asynchronously verify [plaintext] using a background Isolate.
  static Future<bool> verifyPasswordAsync(String plaintext, String encoded) async {
    return await Isolate.run(() => verifyPassword(plaintext, encoded));
  }

  // ─── Public API (Synchronous) ──────────────────────────────────────────────

  /// Hash [password] with a fresh random salt.
  /// Returns a self-contained encoded string suitable for DB storage.
  static String hashPassword(String password) {
    final salt = _randomBytes(_saltBytes);
    final hash = _pbkdf2(utf8.encode(password), salt, _iterations, _hashBytes);
    return 'pbkdf2\$$_iterations\$${base64.encode(salt)}\$${base64.encode(hash)}';
  }

  /// Verify [plaintext] against a stored [encoded] hash string.
  /// Returns true only if they match.
  static bool verifyPassword(String plaintext, String encoded) {
    try {
      final parts = encoded.split('\$');
      if (parts.length != 4 || parts[0] != 'pbkdf2') return false;

      final iterations = int.parse(parts[1]);
      final salt       = base64.decode(parts[2]);
      final storedHash = base64.decode(parts[3]);

      final computed = _pbkdf2(utf8.encode(plaintext), salt, iterations, _hashBytes);
      return _constantTimeEqual(computed, storedHash);
    } catch (_) {
      return false;
    }
  }

  /// Returns true if [encoded] looks like a PBKDF2 hash (not a legacy plaintext).
  static bool isHashed(String value) => value.startsWith('pbkdf2\$');

  // ─── PBKDF2-SHA256 (pure Dart) ─────────────────────────────────────────────

  static Uint8List _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int dkLen,
  ) {
    // PBKDF2-HMAC-SHA256 — RFC 2898 §5.2
    const hLen = 32; // SHA-256 output bytes
    final blocks = (dkLen / hLen).ceil();
    final dk = Uint8List(blocks * hLen);

    for (int i = 1; i <= blocks; i++) {
      // U1 = HMAC(password, salt || INT(i))
      final saltBlock = Uint8List(salt.length + 4);
      saltBlock.setAll(0, salt);
      saltBlock[salt.length]     = (i >> 24) & 0xFF;
      saltBlock[salt.length + 1] = (i >> 16) & 0xFF;
      saltBlock[salt.length + 2] = (i >>  8) & 0xFF;
      saltBlock[salt.length + 3] =  i        & 0xFF;

      var u = _hmacSha256(password, saltBlock);
      final block = Uint8List.fromList(u);

      for (int j = 1; j < iterations; j++) {
        u = _hmacSha256(password, u);
        for (int k = 0; k < hLen; k++) {
          block[k] ^= u[k];
        }
      }

      dk.setAll((i - 1) * hLen, block);
    }

    return dk.sublist(0, dkLen);
  }

  // ─── HMAC-SHA256 (pure Dart) ───────────────────────────────────────────────

  static List<int> _hmacSha256(List<int> key, List<int> message) {
    const blockSize = 64;

    var k = key.length > blockSize ? _sha256(key) : List<int>.from(key);
    while (k.length < blockSize) k.add(0);

    final iPad = List<int>.generate(blockSize, (i) => k[i] ^ 0x36);
    final oPad = List<int>.generate(blockSize, (i) => k[i] ^ 0x5C);

    final inner = _sha256([...iPad, ...message]);
    return _sha256([...oPad, ...inner]);
  }

  // ─── SHA-256 (pure Dart) ───────────────────────────────────────────────────

  static List<int> _sha256(List<int> message) {
    // Initial hash values (first 32 bits of fractional parts of sqrt of first 8 primes)
    var h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];

    // Round constants
    const k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
      0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
      0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
      0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
      0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
      0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    // Pre-processing: padding
    final bits = message.length * 8;
    final msg = List<int>.from(message)..add(0x80);
    while (msg.length % 64 != 56) msg.add(0);
    for (int i = 7; i >= 0; i--) {
      msg.add((bits >> (i * 8)) & 0xFF);
    }

    // Process each 512-bit chunk
    for (int i = 0; i < msg.length; i += 64) {
      final w = List<int>.filled(64, 0);
      for (int j = 0; j < 16; j++) {
        w[j] = (msg[i + j * 4]     << 24) |
               (msg[i + j * 4 + 1] << 16) |
               (msg[i + j * 4 + 2] <<  8) |
               (msg[i + j * 4 + 3]);
      }
      for (int j = 16; j < 64; j++) {
        final s0 = _rotr(w[j - 15], 7) ^ _rotr(w[j - 15], 18) ^ (w[j - 15] >>> 3);
        final s1 = _rotr(w[j -  2], 17) ^ _rotr(w[j -  2], 19) ^ (w[j - 2] >>> 10);
        w[j] = _add(w[j - 16], s0, w[j - 7], s1);
      }

      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];

      for (int j = 0; j < 64; j++) {
        final S1   = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch   = (e & f) ^ (~e & g);
        final temp1 = _add(hh, S1, ch, k[j], w[j]);
        final S0   = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj  = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = _add(S0, maj);

        hh = g; g = f; f = e;
        e = _add(d, temp1);
        d = c; c = b; b = a;
        a = _add(temp1, temp2);
      }

      h[0] = _add(h[0], a);
      h[1] = _add(h[1], b);
      h[2] = _add(h[2], c);
      h[3] = _add(h[3], d);
      h[4] = _add(h[4], e);
      h[5] = _add(h[5], f);
      h[6] = _add(h[6], g);
      h[7] = _add(h[7], hh);
    }

    final result = <int>[];
    for (final word in h) {
      result.addAll([(word >> 24) & 0xFF, (word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF]);
    }
    return result;
  }

  static int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

  static int _add(int a, [int b = 0, int c = 0, int d = 0, int e = 0]) =>
      (a + b + c + d + e) & 0xFFFFFFFF;

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int count) {
    final rng    = Random.secure();
    final bytes  = Uint8List(count);
    for (int i = 0; i < count; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  /// Constant-time equality to prevent timing attacks.
  static bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
