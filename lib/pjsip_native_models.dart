enum PjsipLifecycleState {
  idle,
  initializing,
  created,
  started,
  stopping,
  error,
  unknown;

  static PjsipLifecycleState fromNative(Object? value) {
    switch (value?.toString()) {
      case 'idle':
        return PjsipLifecycleState.idle;
      case 'initializing':
        return PjsipLifecycleState.initializing;
      case 'created':
        return PjsipLifecycleState.created;
      case 'started':
        return PjsipLifecycleState.started;
      case 'stopping':
        return PjsipLifecycleState.stopping;
      case 'error':
        return PjsipLifecycleState.error;
      default:
        return PjsipLifecycleState.unknown;
    }
  }
}

class PjsipOperationResult {
  const PjsipOperationResult({
    required this.success,
    required this.state,
    required this.status,
    required this.message,
    this.accountId = -1,
    this.callId = -1,
  });

  factory PjsipOperationResult.fromMap(Map<String, dynamic> map) {
    final status = map['status'];
    return PjsipOperationResult(
      success: map['success'] == true,
      state: PjsipLifecycleState.fromNative(map['state']),
      status: status is num ? status.toInt() : -1,
      message: map['message']?.toString() ?? '',
      accountId: map['accountId'] is num
          ? (map['accountId'] as num).toInt()
          : -1,
      callId: map['callId'] is num ? (map['callId'] as num).toInt() : -1,
    );
  }

  final bool success;
  final PjsipLifecycleState state;
  final int status;
  final String message;
  final int accountId;
  final int callId;
}

enum PjsipMediaSecurity {
  none('none', '普通 RTP'),
  sdesSrtp('sdes_srtp', 'SDES-SRTP'),
  dtlsSrtp('dtls_srtp', 'DTLS-SRTP'),
  optionalDtlsFirst('optional_dtls_first', '可选 SRTP，优先 DTLS'),
  optionalSdesFirst('optional_sdes_first', '可选 SRTP，优先 SDES');

  const PjsipMediaSecurity(this.value, this.label);

  final String value;
  final String label;
}

class PjsipAccountConfig {
  const PjsipAccountConfig({
    required this.username,
    required this.password,
    required this.host,
    this.authUsername = '',
    this.transport = 'udp',
    this.port = 0,
    this.mediaSecurity = PjsipMediaSecurity.none,
    this.stunEnabled = false,
    this.stunServer = '',
    this.stunPort = 3478,
    this.iceEnabled = false,
    this.tlsVerifyServer = false,
  });

  final String username;
  final String authUsername;
  final String password;
  final String host;
  final String transport;
  final int port;
  final PjsipMediaSecurity mediaSecurity;
  final bool stunEnabled;
  final String stunServer;
  final int stunPort;
  final bool iceEnabled;
  final bool tlsVerifyServer;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'username': username.trim(),
      'authUsername': authUsername.trim(),
      'password': password,
      'host': host.trim(),
      'transport': transport,
      'port': port,
      'mediaSecurity': mediaSecurity.value,
      'stunEnabled': stunEnabled,
      'stunServer': stunServer.trim(),
      'stunPort': stunPort,
      'iceEnabled': iceEnabled,
      'tlsVerifyServer': tlsVerifyServer,
    };
  }
}

enum PjsipRegistrationState {
  registering,
  registered,
  unregistered,
  failed;
}

class PjsipRegistrationEvent {
  const PjsipRegistrationEvent({
    required this.accountId,
    required this.status,
    required this.expires,
    required this.registered,
    required this.message,
    required this.state,
    required this.accountUri,
  });

  factory PjsipRegistrationEvent.fromMap(Map<String, dynamic> map) {
    final status = map['status'] is num ? (map['status'] as num).toInt() : 0;
    final expires =
        map['expires'] is num ? (map['expires'] as num).toInt() : 0;
    final registered = map['registered'] == true;
    final message = map['message']?.toString() ?? '';
    final state = registered
        ? PjsipRegistrationState.registered
        : status >= 300
            ? PjsipRegistrationState.failed
            : status == 200 && expires == 0
                ? PjsipRegistrationState.unregistered
                : message == 'SIP account unregistered'
                    ? PjsipRegistrationState.unregistered
                    : PjsipRegistrationState.registering;
    return PjsipRegistrationEvent(
      accountId: map['accountId'] is num
          ? (map['accountId'] as num).toInt()
          : -1,
      status: status,
      expires: expires,
      registered: registered,
      message: message,
      state: state,
      accountUri: map['accountUri']?.toString() ?? '',
    );
  }

  final int accountId;
  final int status;
  final int expires;
  final bool registered;
  final String message;
  final PjsipRegistrationState state;
  final String accountUri;
}

enum PjsipCallState {
  idle,
  calling,
  incoming,
  early,
  connecting,
  confirmed,
  disconnected,
  unknown;

  static PjsipCallState fromNative(Object? value) {
    final state = value is num ? value.toInt() : -1;
    switch (state) {
      case 0:
        return PjsipCallState.idle;
      case 1:
        return PjsipCallState.calling;
      case 2:
        return PjsipCallState.incoming;
      case 3:
        return PjsipCallState.early;
      case 4:
        return PjsipCallState.connecting;
      case 5:
        return PjsipCallState.confirmed;
      case 6:
        return PjsipCallState.disconnected;
      default:
        return PjsipCallState.unknown;
    }
  }
}

class PjsipCallEvent {
  const PjsipCallEvent({
    required this.callId,
    required this.accountId,
    required this.state,
    required this.nativeState,
    required this.mediaStatus,
    required this.lastStatus,
    required this.incoming,
    required this.remoteUri,
    required this.message,
  });

  factory PjsipCallEvent.fromMap(Map<String, dynamic> map) {
    final nativeState =
        map['callState'] is num ? (map['callState'] as num).toInt() : -1;
    return PjsipCallEvent(
      callId: map['callId'] is num ? (map['callId'] as num).toInt() : -1,
      accountId:
          map['accountId'] is num ? (map['accountId'] as num).toInt() : -1,
      state: PjsipCallState.fromNative(nativeState),
      nativeState: nativeState,
      mediaStatus:
          map['mediaStatus'] is num ? (map['mediaStatus'] as num).toInt() : 0,
      lastStatus:
          map['lastStatus'] is num ? (map['lastStatus'] as num).toInt() : 0,
      incoming: map['incoming'] == true,
      remoteUri: map['remoteUri']?.toString() ?? '',
      message: map['message']?.toString() ?? '',
    );
  }

  final int callId;
  final int accountId;
  final PjsipCallState state;
  final int nativeState;
  final int mediaStatus;
  final int lastStatus;
  final bool incoming;
  final String remoteUri;
  final String message;

  bool get isActive =>
      state != PjsipCallState.idle &&
      state != PjsipCallState.disconnected &&
      state != PjsipCallState.unknown;
  bool get canAnswer =>
      incoming &&
      (state == PjsipCallState.incoming || state == PjsipCallState.early);
  bool get isConnected => state == PjsipCallState.confirmed;
  bool get isOnHold => mediaStatus == 2 || mediaStatus == 3;
}

class PjsipStatusEvent {
  const PjsipStatusEvent({
    required this.state,
    required this.message,
  });

  factory PjsipStatusEvent.fromMap(Map<String, dynamic> map) {
    return PjsipStatusEvent(
      state: PjsipLifecycleState.fromNative(map['state']),
      message: map['message']?.toString() ?? '',
    );
  }

  final PjsipLifecycleState state;
  final String message;
}

class PjsipLogEvent {
  const PjsipLogEvent({
    required this.level,
    required this.message,
    required this.receivedAt,
  });

  factory PjsipLogEvent.fromMap(Map<String, dynamic> map) {
    final level = map['level'];
    return PjsipLogEvent(
      level: level is num ? level.toInt() : 0,
      message: map['message']?.toString() ?? '',
      receivedAt: DateTime.now(),
    );
  }

  final int level;
  final String message;
  final DateTime receivedAt;
}

class PjsipAudioLevels {
  const PjsipAudioLevels({
    required this.success,
    required this.status,
    required this.microphoneLevel,
    required this.remoteLevel,
  });

  factory PjsipAudioLevels.fromMap(Map<String, dynamic> map) {
    return PjsipAudioLevels(
      success: map['success'] == true,
      status: (map['status'] as num?)?.toInt() ?? -1,
      microphoneLevel:
          ((map['microphoneLevel'] as num?)?.toInt() ?? 0)
              .clamp(0, 255)
              .toInt(),
      remoteLevel:
          ((map['remoteLevel'] as num?)?.toInt() ?? 0)
              .clamp(0, 255)
              .toInt(),
    );
  }

  final bool success;
  final int status;
  final int microphoneLevel;
  final int remoteLevel;
}

enum PjsipAudioDeviceStatus { ready, switching, error, unknown }

class PjsipAudioDeviceState {
  const PjsipAudioDeviceState({
    required this.status,
    required this.captureDevice,
    required this.playbackDevice,
    required this.message,
  });

  factory PjsipAudioDeviceState.fromMap(Map<String, dynamic> map) {
    final state = map['state'] as String? ?? '';
    return PjsipAudioDeviceState(
      status: switch (state) {
        'ready' => PjsipAudioDeviceStatus.ready,
        'switching' => PjsipAudioDeviceStatus.switching,
        'error' => PjsipAudioDeviceStatus.error,
        _ => PjsipAudioDeviceStatus.unknown,
      },
      captureDevice: map['captureDevice'] as String? ?? '未知设备',
      playbackDevice: map['playbackDevice'] as String? ?? '未知设备',
      message: map['message'] as String? ?? '',
    );
  }

  final PjsipAudioDeviceStatus status;
  final String captureDevice;
  final String playbackDevice;
  final String message;
}

class PjsipBridgeException implements Exception {
  const PjsipBridgeException({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'PjsipBridgeException($code): $message';
}
