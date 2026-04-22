import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/database_service.dart';

class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  final _supabase = Supabase.instance.client;
  StreamSubscription? _connectivitySub;
  bool _isSyncing = false;

  void init() {
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen((results) {
      final hasConnection = results.any(
        (r) => r != ConnectivityResult.none,
      );
      if (hasConnection) syncNow();
    });
  }

  void dispose() => _connectivitySub?.cancel();

  // ── Check if this is a fresh install ─────────────────────────────────────

  Future<bool> _isFreshInstall() async {
    final db     = await DatabaseService.instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM employees',
    );
    final count = result.first.values.first as int;
    return count == 0;
  }

  // ── Seed local DB from Supabase on fresh install ──────────────────────────

  Future<void> seedIfNeeded() async {
    try {
      // Check connectivity first
      final connectivity = await Connectivity().checkConnectivity();
      final hasConnection = connectivity.any(
        (r) => r != ConnectivityResult.none,
      );

      if (!hasConnection) {
        print('[SyncService] No internet — skipping seed.');
        return;
      }

      final fresh = await _isFreshInstall();
      if (!fresh) {
        print('[SyncService] DB already has data — skipping seed.');
        return;
      }

      print('[SyncService] Fresh install detected — seeding from Supabase...');
      final db = await DatabaseService.instance.database;

      // 1. Seed departments
      final departments = await _supabase.from('departments').select();
      for (final row in departments) {
        await db.insert(
          'departments',
          {'id': row['id'], 'name': row['name']},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[SyncService] ✅ Seeded ${departments.length} departments');

      // 2. Seed employees (includes password, skips facial_embedding)
      final employees = await _supabase.from('employees').select();
      for (final row in employees) {
        await db.insert(
          'employees',
          {
            'id':               row['id'],
            'name':             row['name'],
            'age':              row['age'],
            'sex':              row['sex'],
            'position':         row['position'],
            'department':       row['department'],
            'emp_id':           row['emp_id'],
            'email':            row['email'] ?? '',
            'is_admin':         row['is_admin']   ?? 0,
            'is_deleted':       row['is_deleted'] ?? 0,
            'username':         row['username'],
            'password':         row['password'],  // ✅ included for admin
            'facial_embedding': '',               // stays local only
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[SyncService] ✅ Seeded ${employees.length} employees');

      // 3. Seed attendance
      final attendance = await _supabase.from('attendance').select();
      for (final row in attendance) {
        await db.insert(
          'attendance',
          {
            'id':          row['id'],
            'employee_id': row['employee_id'],
            'timestamp':   row['timestamp'],
            'type':        row['type'],
            'status':      row['status'] ?? 'Normal',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[SyncService] ✅ Seeded ${attendance.length} attendance records');

      // 4. Seed system settings
      final settings = await _supabase.from('system_settings').select();
      for (final row in settings) {
        await db.insert(
          'system_settings',
          {'key': row['key'], 'value': row['value']},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      print('[SyncService] ✅ Seeded ${settings.length} settings');

      print('[SyncService] 🎉 Seed complete!');
    } catch (e, stack) {
      print('[SyncService] ❌ Seed failed: $e');
      print('[SyncService] Stack: $stack');
    }
  }

  // ── Queue a local change ──────────────────────────────────────────────────

  Future<void> enqueue({
    required String tableName,
    required String operation,
    required int recordId,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final db = await DatabaseService.instance.database;
      await db.insert('sync_queue', {
        'table_name': tableName,
        'operation':  operation,
        'record_id':  recordId,
        'payload':    jsonEncode(payload),
        'created_at': DateTime.now().toIso8601String(),
      });
      print('[SyncService] ✅ Enqueued $operation on $tableName id=$recordId');
      await syncNow();
    } catch (e) {
      print('[SyncService] ❌ Enqueue failed: $e');
    }
  }

  // ── Push all queued changes to Supabase ───────────────────────────────────

  Future<void> syncNow() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final db    = await DatabaseService.instance.database;
      final queue = await db.query('sync_queue', orderBy: 'id ASC');

      if (queue.isEmpty) {
        print('[SyncService] Nothing to sync.');
        return;
      }

      print('[SyncService] Syncing ${queue.length} item(s)...');

      for (final item in queue) {
        final queueId   = item['id']         as int;
        final table     = item['table_name'] as String;
        final operation = item['operation']  as String;
        final payload   = jsonDecode(item['payload'] as String)
            as Map<String, dynamic>;

        print('[SyncService] Processing: $operation on $table → $payload');

        bool success = false;
        try {
          switch (operation) {
            case 'INSERT':
              await _supabase.from(table).upsert(payload);
              success = true;
            case 'UPDATE':
              await _supabase
                  .from(table)
                  .update(payload)
                  .eq('id', payload['id']);
              success = true;
            case 'DELETE':
              await _supabase
                  .from(table)
                  .update({'is_deleted': 1})
                  .eq('id', payload['id']);
              success = true;
          }
          print('[SyncService] ✅ Synced $operation on $table id=$queueId');
        } catch (e, stack) {
          print('[SyncService] ❌ Failed to sync item $queueId');
          print('[SyncService] Error: $e');
          print('[SyncService] Stack: $stack');
        }

        if (success) {
          await db.delete('sync_queue',
              where: 'id = ?', whereArgs: [queueId]);
        }
      }

      print('[SyncService] Sync complete.');
    } finally {
      _isSyncing = false;
    }
  }
}