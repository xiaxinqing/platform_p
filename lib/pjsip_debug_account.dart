import 'pjsip_native_bridge.dart';

PjsipAccountConfig? createDebugTestAccount() {
  PjsipAccountConfig? account;
  assert(() {
    account = const PjsipAccountConfig(
      username: '6523',
      password: 'veserve888',
      host: '139.59.100.15',
    );
    return true;
  }());
  return account;
}
