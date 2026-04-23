import 'package:flutter_riverpod/flutter_riverpod.dart';

class SyncRefreshNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void refresh() => state = state + 1;
}

final syncRefreshCountProvider =
    NotifierProvider<SyncRefreshNotifier, int>(SyncRefreshNotifier.new);