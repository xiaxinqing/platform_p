import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pjsip_native_models.dart';

export 'pjsip_native_models.dart';

class PjsipNativeBridge {
  PjsipNativeBridge._() {
    _channel.setMethodCallHandler(_handleNativeCall);
    _settingsReady = _loadSettings();
  }

  static final PjsipNativeBridge instance = PjsipNativeBridge._();
  static const MethodChannel _channel = MethodChannel('platform_p/pjsip');
  static const String _autoHoldOnIncomingKey =
      'pjsip.auto_hold_on_incoming';

  late final Future<void> _settingsReady;
  SharedPreferences? _preferences;
  Future<Map<String, String>>? _audioCuePaths;

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
  final Map<int, PjsipRegistrationEvent> _registrations =
      <int, PjsipRegistrationEvent>{};
  final Map<int, PjsipAccountConfig> _accountConfigs =
      <int, PjsipAccountConfig>{};
  PjsipCallEvent? _currentCall;
  final Map<int, PjsipCallEvent> _calls = <int, PjsipCallEvent>{};
  bool _autoHoldOnIncoming = true;

  Stream<PjsipStatusEvent> get statusStream => _statusEvents.stream;
  Stream<PjsipLogEvent> get logStream => _logEvents.stream;
  Stream<PjsipRegistrationEvent> get registrationStream =>
      _registrationEvents.stream;
  Stream<PjsipCallEvent> get callStream => _callEvents.stream;
  PjsipLifecycleState get currentState => _currentState;
  PjsipRegistrationEvent? get currentRegistration => _currentRegistration;
  Map<int, PjsipRegistrationEvent> get currentRegistrations =>
      Map<int, PjsipRegistrationEvent>.unmodifiable(_registrations);
  Map<int, PjsipAccountConfig> get currentAccountConfigs =>
      Map<int, PjsipAccountConfig>.unmodifiable(_accountConfigs);
  PjsipCallEvent? get currentCall => _currentCall;
  Map<int, PjsipCallEvent> get currentCalls =>
      Map<int, PjsipCallEvent>.unmodifiable(_calls);
  bool get autoHoldOnIncoming => _autoHoldOnIncoming;
  Future<void> get settingsReady => _settingsReady;

  Future<PjsipOperationResult> initialize() {
    return _enqueue(() async {
      await _settingsReady;
      if (_currentState == PjsipLifecycleState.started) {
        await _syncAutoHoldSetting();
        await _syncAudioCuePaths();
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
      final result = await _invoke('initialize');
      if (result.success) {
        await _syncAutoHoldSetting();
        await _syncAudioCuePaths();
      }
      return result;
    });
  }

  Future<PjsipOperationResult> status() => _enqueue(() => _invoke('status'));

  Future<PjsipOperationResult> registerAccount(PjsipAccountConfig config) {
    return _enqueue(() async {
      await _settingsReady;
      if (_currentState != PjsipLifecycleState.started) {
        final initialization = await _invoke('initialize');
        if (!initialization.success) {
          return initialization;
        }
        await _syncAutoHoldSetting();
        await _syncAudioCuePaths();
      }
      final result = await _invoke('registerAccount', config.toMap());
      if (result.success && result.accountId >= 0) {
        _accountConfigs[result.accountId] = config;
      }
      return result;
    });
  }

  Future<PjsipOperationResult> unregisterAccount(int accountId) {
    return _enqueue(
      () async {
        final result = await _invoke(
        'unregisterAccount',
        <String, dynamic>{'accountId': accountId},
        );
        if (result.success) _accountConfigs.remove(accountId);
        return result;
      },
    );
  }

  Future<PjsipOperationResult> makeCall(String destination, int accountId) {
    return _enqueue(
      () => _invoke('makeCall', <String, dynamic>{
        'destination': destination.trim(),
        'accountId': accountId,
      }),
    );
  }

  Future<PjsipOperationResult> answerCall(int callId) =>
      _callControl('answerCall', callId);

  Future<PjsipOperationResult> rejectCall(int callId) =>
      _callControl('rejectCall', callId);

  Future<PjsipOperationResult> hangupCall(int callId) =>
      _callControl('hangupCall', callId);

  Future<PjsipOperationResult> holdCall(int callId) =>
      _callControl('holdCall', callId);

  Future<PjsipOperationResult> resumeCall(int callId) =>
      _callControl('resumeCall', callId);

  Future<PjsipOperationResult> setMicrophoneMuted(bool muted) => _enqueue(
        () => _invoke(
          'setMicrophoneMuted',
          <String, dynamic>{'muted': muted},
        ),
      );

  Future<PjsipOperationResult> setSpeakerMuted(bool muted) => _enqueue(
        () => _invoke(
          'setSpeakerMuted',
          <String, dynamic>{'muted': muted},
        ),
      );

  Future<PjsipOperationResult> sendDtmf(int callId, String digits) => _enqueue(
        () => _invoke(
          'sendDtmf',
          <String, dynamic>{'callId': callId, 'digits': digits},
        ),
      );

  Future<PjsipAudioLevels> getAudioLevels(int callId) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'getAudioLevels',
        <String, dynamic>{'callId': callId},
      );
      return PjsipAudioLevels.fromMap(
        Map<String, dynamic>.from(map ?? const {}),
      );
    } on PlatformException catch (error) {
      throw PjsipBridgeException(
        code: error.code,
        message: error.message ?? '读取音频电平失败',
        details: error.details,
      );
    } on MissingPluginException catch (error) {
      throw PjsipBridgeException(
        code: 'missing_plugin',
        message: '当前平台尚未注册音频电平接口',
        details: error,
      );
    }
  }

  Future<PjsipOperationResult> setAutoHoldOnIncoming(bool enabled) {
    return _enqueue(() async {
      await _settingsReady;
      final result = await _invoke(
        'setAutoHoldOnIncoming',
        <String, dynamic>{'enabled': enabled},
      );
      if (result.success) {
        _autoHoldOnIncoming = enabled;
        final preferences =
            _preferences ?? await SharedPreferences.getInstance();
        _preferences = preferences;
        await preferences.setBool(_autoHoldOnIncomingKey, enabled);
      }
      return result;
    });
  }

  Future<void> _loadSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      _autoHoldOnIncoming =
          preferences.getBool(_autoHoldOnIncomingKey) ?? true;
    } catch (error) {
      debugPrint('[Flutter][PJSIP] 读取通话设定失败，使用默认值: $error');
      _autoHoldOnIncoming = true;
    }
  }

  Future<void> _syncAutoHoldSetting() async {
    await _invoke(
      'setAutoHoldOnIncoming',
      <String, dynamic>{'enabled': _autoHoldOnIncoming},
    );
  }

  Future<void> _syncAudioCuePaths() async {
    try {
      final paths = await (_audioCuePaths ??= _extractAudioCueAssets());
      await _invoke('configureAudioCues', <String, dynamic>{
        'ringtonePath': paths['ringtone'],
        'ringbackPath': paths['ringback'],
        'hangupPath': paths['hangup'],
      });
    } catch (error) {
      debugPrint('[Flutter][PJSIP] 配置通话提示音失败: $error');
    }
  }

  Future<Map<String, String>> _extractAudioCueAssets() async {
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}platform_p_audio',
    );
    await directory.create(recursive: true);
    const assets = <String, String>{
      'ringtone': 'assets/audio/ringtone.wav',
      'ringback': 'assets/audio/ringing_loop.wav',
      'hangup': 'assets/audio/hangup.wav',
    };
    final paths = <String, String>{};
    for (final entry in assets.entries) {
      final data = await rootBundle.load(entry.value);
      final file = File(
        '${directory.path}${Platform.pathSeparator}${entry.key}.wav',
      );
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      paths[entry.key] = file.path;
    }
    return paths;
  }

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
        if (event.state == PjsipRegistrationState.unregistered) {
          _registrations.remove(event.accountId);
          _accountConfigs.remove(event.accountId);
        } else {
          _registrations[event.accountId] = event;
        }
        _registrationEvents.add(event);
        return;
      case 'call':
        final event = PjsipCallEvent.fromMap(map);
        _currentCall = event;
        if (event.state == PjsipCallState.disconnected ||
            event.state == PjsipCallState.idle) {
          _calls.remove(event.callId);
        } else {
          _calls[event.callId] = event;
        }
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
