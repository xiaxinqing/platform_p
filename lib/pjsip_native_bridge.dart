import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pjsip_native_models.dart';

export 'pjsip_native_models.dart';

class PjsipNativeBridge {
  PjsipNativeBridge._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final PjsipNativeBridge instance = PjsipNativeBridge._();
  static const MethodChannel _channel = MethodChannel('platform_p/pjsip');

  final StreamController<PjsipStatusEvent> _statusEvents =
      StreamController<PjsipStatusEvent>.broadcast();
  final StreamController<PjsipLogEvent> _logEvents =
      StreamController<PjsipLogEvent>.broadcast();
  final StreamController<PjsipRegistrationEvent> _registrationEvents =
      StreamController<PjsipRegistrationEvent>.broadcast();
  final StreamController<PjsipCallEvent> _callEvents =
      StreamController<PjsipCallEvent>.broadcast();
  Future<void> _operationTail = Future<void>.value();
  PjsipLifecycleState _currentState = PjsipLifecycleState.idle;
  PjsipRegistrationEvent? _currentRegistration;
  PjsipCallEvent? _currentCall;

  Stream<PjsipStatusEvent> get statusStream => _statusEvents.stream;
  Stream<PjsipLogEvent> get logStream => _logEvents.stream;
  Stream<PjsipRegistrationEvent> get registrationStream =>
      _registrationEvents.stream;
  Stream<PjsipCallEvent> get callStream => _callEvents.stream;
  PjsipLifecycleState get currentState => _currentState;
  PjsipRegistrationEvent? get currentRegistration => _currentRegistration;
  PjsipCallEvent? get currentCall => _currentCall;

  Future<PjsipOperationResult> initialize() {
    return _enqueue(() async {
      if (_currentState == PjsipLifecycleState.started) {
        return const PjsipOperationResult(
          success: true,
          state: PjsipLifecycleState.started,
          status: 0,
          message: 'PJSIP is already initialized',
        );
      }
      _publishStatus(
        const PjsipStatusEvent(
          state: PjsipLifecycleState.initializing,
          message: '正在初始化原生 PJSIP',
        ),
      );
      return _invoke('initialize');
    });
  }

  Future<PjsipOperationResult> status() => _enqueue(() => _invoke('status'));

  Future<PjsipOperationResult> registerAccount(PjsipAccountConfig config) {
    return _enqueue(() async {
      if (_currentState != PjsipLifecycleState.started) {
        final initialization = await _invoke('initialize');
        if (!initialization.success) {
          return initialization;
        }
      }
      return _invoke('registerAccount', config.toMap());
    });
  }

  Future<PjsipOperationResult> unregisterAccount() {
    return _enqueue(() => _invoke('unregisterAccount'));
  }

  Future<PjsipOperationResult> makeCall(String destination) {
    return _enqueue(
      () => _invoke('makeCall', <String, dynamic>{
        'destination': destination.trim(),
      }),
    );
  }

  Future<PjsipOperationResult> answerCall(int callId) =>
      _callControl('answerCall', callId);

  Future<PjsipOperationResult> rejectCall(int callId) =>
      _callControl('rejectCall', callId);

  Future<PjsipOperationResult> hangupCall(int callId) =>
      _callControl('hangupCall', callId);

  Future<PjsipOperationResult> _callControl(String method, int callId) {
    return _enqueue(
      () => _invoke(method, <String, dynamic>{'callId': callId}),
    );
  }

  Future<PjsipOperationResult> shutdown() {
    return _enqueue(() async {
      if (_currentState == PjsipLifecycleState.idle) {
        return const PjsipOperationResult(
          success: true,
          state: PjsipLifecycleState.idle,
          status: 0,
          message: 'PJSIP is already stopped',
        );
      }
      _publishStatus(
        const PjsipStatusEvent(
          state: PjsipLifecycleState.stopping,
          message: '正在关闭原生 PJSIP',
        ),
      );
      return _invoke('shutdown');
    });
  }

  Future<PjsipOperationResult> _enqueue(
    Future<PjsipOperationResult> Function() operation,
  ) {
    final completer = Completer<PjsipOperationResult>();
    _operationTail = _operationTail.then<void>((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<PjsipOperationResult> _invoke(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      final result = PjsipOperationResult.fromMap(
        Map<String, dynamic>.from(map ?? const {}),
      );
      _publishStatus(
        PjsipStatusEvent(state: result.state, message: result.message),
      );
      debugPrint('[Flutter][PJSIP][' + method + '] ' + result.message);
      return result;
    } on PlatformException catch (error) {
      final exception = PjsipBridgeException(
        code: error.code,
        message: error.message ?? '原生 PJSIP 调用失败',
        details: error.details,
      );
      _publishError(exception);
      throw exception;
    } on MissingPluginException catch (error) {
      final exception = PjsipBridgeException(
        code: 'missing_plugin',
        message: '当前平台尚未注册 PJSIP 原生通道',
        details: error,
      );
      _publishError(exception);
      throw exception;
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'event' || call.arguments is! Map) return;
    final map = Map<String, dynamic>.from(call.arguments as Map);
    switch (map['type']) {
      case 'status':
        _publishStatus(PjsipStatusEvent.fromMap(map));
        return;
      case 'log':
        final event = PjsipLogEvent.fromMap(map);
        debugPrint(
          '[Flutter][PJSIP][L' +
              event.level.toString() +
              '] ' +
              event.message,
        );
        _logEvents.add(event);
        return;
      case 'registration':
        final event = PjsipRegistrationEvent.fromMap(map);
        _currentRegistration = event;
        _registrationEvents.add(event);
        return;
      case 'call':
        final event = PjsipCallEvent.fromMap(map);
        _currentCall = event;
        _callEvents.add(event);
        debugPrint(
          '[Flutter][PJSIP][CALL] id=${event.callId} '
          'state=${event.state.name} remote=${event.remoteUri}',
        );
        return;
      default:
        debugPrint('[Flutter][PJSIP] Unknown native event: ' + map.toString());
    }
  }

  void _publishStatus(PjsipStatusEvent event) {
    _currentState = event.state;
    _statusEvents.add(event);
  }

  void _publishError(PjsipBridgeException error) {
    _publishStatus(
      PjsipStatusEvent(
        state: PjsipLifecycleState.error,
        message: error.message,
      ),
    );
  }
}
