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

class PjsipAccountConfig {
  const PjsipAccountConfig({
    required this.username,
    required this.password,
    required this.host,
    this.authUsername = '',
    this.transport = 'udp',
  });

  final String username;
  final String authUsername;
  final String password;
  final String host;
  final String transport;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'username': username.trim(),
      'authUsername': authUsername.trim(),
      'password': password,
      'host': host.trim(),
      'transport': transport,
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
    );
  }

  final int accountId;
  final int status;
  final int expires;
  final bool registered;
  final String message;
  final PjsipRegistrationState state;
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
