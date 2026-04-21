import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
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

      // Try to sync immediately instead of waiting for connectivity change
      await syncNow();
    } catch (e) {
      print('[SyncService] ❌ Enqueue failed: $e');
    }
  }

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