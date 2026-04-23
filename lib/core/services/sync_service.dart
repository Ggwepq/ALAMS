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

  StreamSubscription?         _connectivitySub;
  final List<RealtimeChannel> _channels = [];
  Timer?                      _periodicTimer;
  bool                        _isSyncing = false;

  // ── Init / Dispose ────────────────────────────────────────────────────────

  void init() {
    // Push queued changes + pull latest whenever connectivity is restored
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        syncNow();
        pullFromSupabase();
      }
    });

    // Real-time subscriptions for instant cross-device updates
    _subscribeRealtime();

    // Fallback periodic pull every 30 seconds
    _periodicTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => pullFromSupabase(),
    );
  }

  void dispose() {
    _connectivitySub?.cancel();
    _periodicTimer?.cancel();
    for (final ch in _channels) {
      _supabase.removeChannel(ch);
    }
    _channels.clear();
  }

  // ── Real-time Supabase subscriptions ─────────────────────────────────────

  void _subscribeRealtime() {
    final tables = ['employees', 'departments', 'attendance', 'system_settings'];

    for (final table in tables) {
      final channel = _supabase
          .channel('realtime-$table')
          .onPostgresChanges(
            event:    PostgresChangeEvent.all,
            schema:   'public',
            table:    table,
            callback: (payload) async {
              print('[SyncService] 📡 Realtime ${payload.eventType} on $table');
              await _applyRealtimeChange(table, payload);
            },
          )
          .subscribe();

      _channels.add(channel);
    }

    print('[SyncService] ✅ Subscribed to real-time on all tables.');
  }

  Future<void> _applyRealtimeChange(
    String table,
    PostgresChangePayload payload,
  ) async {
    try {
      final db  = await DatabaseService.instance.database;
      final row = payload.newRecord;
      final old = payload.oldRecord;

      switch (payload.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          if (row.isEmpty) return;
          final localRow = await _remoteToLocal(table, row, db);
          await db.insert(
            table,
            localRow,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          print('[SyncService] ✅ Applied ${payload.eventType} on $table id=${row['id']}');

        case PostgresChangeEvent.delete:
          final id = old['id'];
          if (id == null) return;
          if (table == 'employees') {
            await db.update(
              'employees',
              {'is_deleted': 1},
              where:     'id = ?',
              whereArgs: [id],
            );
          } else {
            await db.delete(table, where: 'id = ?', whereArgs: [id]);
          }
          print('[SyncService] ✅ Applied DELETE on $table id=$id');

        default:
          break;
      }
    } catch (e) {
      print('[SyncService] ❌ Failed to apply realtime change on $table: $e');
    }
  }

  // ── Pull ALL latest data from Supabase ────────────────────────────────────

  Future<void> pullFromSupabase() async {
    try {
      final connectivity  = await Connectivity().checkConnectivity();
      final hasConnection = connectivity.any((r) => r != ConnectivityResult.none);
      if (!hasConnection) {
        print('[SyncService] No internet — skipping pull.');
        return;
      }

      print('[SyncService] 🔄 Pulling latest data from Supabase...');
      final db = await DatabaseService.instance.database;

      // ── Departments ──────────────────────────────────────────────────────
      final departments = await _supabase.from('departments').select();
      for (final row in departments) {
        await db.insert(
          'departments',
          {'id': row['id'], 'name': row['name']},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      // ── Employees (with facial_embedding) ───────────────────────────────
      final employees = await _supabase.from('employees').select();
      for (final row in employees) {
        final localRow = await _remoteToLocal('employees', row, db);
        await db.insert(
          'employees',
          localRow,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      // ── Attendance ───────────────────────────────────────────────────────
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

      // ── System Settings ──────────────────────────────────────────────────
      final settings = await _supabase.from('system_settings').select();
      for (final row in settings) {
        await db.insert(
          'system_settings',
          {'key': row['key'], 'value': row['value']},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      print('[SyncService] ✅ Pull complete — '
          'depts: ${departments.length}, '
          'employees: ${employees.length}, '
          'attendance: ${attendance.length}, '
          'settings: ${settings.length}');
    } catch (e, stack) {
      print('[SyncService] ❌ Pull failed: $e\n$stack');
    }
  }

  // ── Seed on startup (always pulls, not just fresh install) ────────────────

  Future<void> seedIfNeeded() async {
    try {
      final connectivity  = await Connectivity().checkConnectivity();
      final hasConnection = connectivity.any((r) => r != ConnectivityResult.none);
      if (!hasConnection) {
        print('[SyncService] No internet — skipping seed.');
        return;
      }
      // Always pull so every device stays up to date on startup
      await pullFromSupabase();
    } catch (e) {
      print('[SyncService] ❌ Seed failed: $e');
    }
  }

  // ── Queue a local change and push immediately ─────────────────────────────

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

  // ── Push all queued changes to Supabase ──────────────────────────────────

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
        final payload   = jsonDecode(item['payload'] as String) as Map<String, dynamic>;

        bool success = false;
        try {
          // facial_embedding is now included in remote payload
          final remotePayload = Map<String, dynamic>.from(payload);

          switch (operation) {
            case 'INSERT':
              await _supabase.from(table).upsert(remotePayload);
              success = true;

            case 'UPDATE':
              await _supabase
                  .from(table)
                  .update(remotePayload)
                  .eq('id', payload['id']);
              success = true;

            case 'DELETE':
              if (table == 'employees') {
                // Soft-delete — mark as deleted in Supabase
                await _supabase
                    .from(table)
                    .update({'is_deleted': 1})
                    .eq('id', payload['id']);
              } else {
                // Hard-delete for non-employee tables
                await _supabase
                    .from(table)
                    .delete()
                    .eq('id', payload['id']);
              }
              success = true;
          }

          print('[SyncService] ✅ Synced $operation on $table id=${payload['id']}');
        } catch (e, stack) {
          print('[SyncService] ❌ Failed to sync item $queueId: $e\n$stack');
        }

        if (success) {
          await db.delete('sync_queue', where: 'id = ?', whereArgs: [queueId]);
        }
      }

      print('[SyncService] Sync complete.');
    } finally {
      _isSyncing = false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Convert a Supabase row → local DB row.
  ///
  /// For employees: uses "longest wins" strategy for facial_embedding.
  /// Whichever value has more data (remote or local) is kept.
  /// This means:
  ///   - A newly registered face on Device A propagates to Device B ✅
  ///   - A blank/missing remote value never wipes a local embedding ✅
  Future<Map<String, dynamic>> _remoteToLocal(
    String table,
    Map<String, dynamic> row,
    Database db,
  ) async {
    if (table != 'employees') return Map<String, dynamic>.from(row);

    // Read existing local embedding (if any)
    final existing = await db.query(
      'employees',
      columns:   ['facial_embedding'],
      where:     'id = ?',
      whereArgs: [row['id']],
      limit:     1,
    );

    final localEmbedding  = existing.isNotEmpty
        ? (existing.first['facial_embedding'] as String? ?? '')
        : '';
    final remoteEmbedding = row['facial_embedding'] as String? ?? '';

    // Keep whichever has more data
    final bestEmbedding = remoteEmbedding.length >= localEmbedding.length
        ? remoteEmbedding
        : localEmbedding;

    return {
      'id':               row['id'],
      'name':             row['name'],
      'age':              row['age'],
      'sex':              row['sex'],
      'position':         row['position'],
      'department':       row['department'],
      'emp_id':           row['emp_id'],
      'email':            row['email']      ?? '',
      'is_admin':         row['is_admin']   ?? 0,
      'is_deleted':       row['is_deleted'] ?? 0,
      'username':         row['username'],
      'password':         row['password'],
      'facial_embedding': bestEmbedding,   // ✅ synced across all devices
    };
  }
}