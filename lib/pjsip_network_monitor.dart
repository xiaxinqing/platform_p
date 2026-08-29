import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'pjsip_native_bridge.dart';

class PjsipNetworkMonitor {
  PjsipNetworkMonitor({required this.bridge, this.onMessage});

  final PjsipNativeBridge bridge;
  final ValueChanged<String>? onMessage;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounce;
  Set<ConnectivityResult>? _lastResults;

  Future<void> start() async {
    if (_subscription != null) return;
    _lastResults = (await _connectivity.checkConnectivity()).toSet();
    _subscription = _connectivity.onConnectivityChanged.listen(_onChanged);
  }

  void _onChanged(List<ConnectivityResult> results) {
    final current = results.toSet();
    if (setEquals(current, _lastResults)) return;
    _lastResults = current;
    _debounce?.cancel();

    if (current.isEmpty || current.contains(ConnectivityResult.none)) {
      onMessage?.call('网络已断开，等待连接恢复');
      return;
    }

    onMessage?.call('检测到网络变化，正在准备恢复 SIP');
    _debounce = Timer(const Duration(seconds: 1), () async {
      if (bridge.currentState != PjsipLifecycleState.started) return;
      try {
        final result = await bridge.handleNetworkChange();
        onMessage?.call(result.message);
      } on PjsipBridgeException catch (error) {
        onMessage?.call(error.message);
      }
    });
  }

  void dispose() {
    _debounce?.cancel();
    _subscription?.cancel();
  }
}
