import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/database_service.dart';
import '../providers/sync_refresh_provider.dart';

class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  final _supabase = Supabase.instance.client;

  StreamSubscription?         _connectivitySub;
  final List<RealtimeChannel> _channels = [];
  Timer?                      _periodicTimer;
  bool                        _isSyncing = false;

  // ── Riverpod container — injected from main.dart after ProviderScope ──────
  ProviderContainer? _container;

  void setContainer(ProviderContainer container) {
    _container = container;
  }

  void _triggerUIRefresh() {
    final container = _container;
    if (container == null) return;
    try {
      container.read(syncRefreshCountProvider.notifier).refresh();
      print('[SyncService] 🔔 UI refresh triggered');
    } catch (e) {
      print('[SyncService] ⚠️ Could not trigger UI refresh: $e');
    }
  }

  // ── Init / Dispose ────────────────────────────────────────────────────────

  void init() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        syncNow();
        pullFromSupabase();
      }
    });

    _subscribeRealtime();

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
              _triggerUIRefresh();
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
          final pk = table == 'system_settings' ? 'key' : 'id';
          final pkValue = old[pk];
          if (pkValue == null) return;

          if (table == 'employees') {
            await db.update(
              'employees',
              {'is_deleted': 1},
              where:     'id = ?',
              whereArgs: [pkValue],
            );
          } else {
            await db.delete(table, where: '$pk = ?', whereArgs: [pkValue]);
          }
          print('[SyncService] ✅ Applied DELETE on $table $pk=$pkValue');

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

      // ── Employees ────────────────────────────────────────────────────────
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

      // Notify UI after full pull completes
      _triggerUIRefresh();

      print('[SyncService] ✅ Pull complete — '
          'depts: ${departments.length}, '
          'employees: ${employees.length}, '
          'attendance: ${attendance.length}, '
          'settings: ${settings.length}');
    } catch (e, stack) {
      print('[SyncService] ❌ Pull failed: $e\n$stack');
    }
  }

  // ── Seed on startup ───────────────────────────────────────────────────────

  Future<void> seedIfNeeded() async {
    try {
      final connectivity  = await Connectivity().checkConnectivity();
      final hasConnection = connectivity.any((r) => r != ConnectivityResult.none);
      if (!hasConnection) {
        print('[SyncService] No internet — skipping seed.');
        return;
      }
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
        final payload   = jsonDecode(item['payload'] as String)
            as Map<String, dynamic>;

        bool success = false;
        try {
          final remotePayload = Map<String, dynamic>.from(payload);
          final pk = table == 'system_settings' ? 'key' : 'id';
          final pkValue = payload[pk];

          switch (operation) {
            case 'INSERT':
              await _supabase.from(table).upsert(remotePayload);
              success = true;

            case 'UPDATE':
              await _supabase
                  .from(table)
                  .update(remotePayload)
                  .eq(pk, pkValue);
              success = true;

            case 'DELETE':
              if (table == 'employees') {
                await _supabase
                    .from(table)
                    .update({'is_deleted': 1})
                    .eq(pk, pkValue);
              } else {
                await _supabase
                    .from(table)
                    .delete()
                    .eq(pk, pkValue);
              }
              success = true;
          }

          print('[SyncService] ✅ Synced $operation on $table $pk=$pkValue');
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

  Future<Map<String, dynamic>> _remoteToLocal(
    String table,
    Map<String, dynamic> row,
    Database db,
  ) async {
    if (table != 'employees') return Map<String, dynamic>.from(row);

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
      'facial_embedding': bestEmbedding,
    };
  }
}