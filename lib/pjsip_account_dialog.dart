import 'package:flutter/material.dart';

import 'pjsip_debug_account.dart';
import 'pjsip_native_models.dart';

Future<PjsipAccountConfig?> showPjsipAccountDialog(BuildContext context) {
  return showDialog<PjsipAccountConfig>(
    context: context,
    builder: (context) => const _PjsipAccountDialog(),
  );
}

class _PjsipAccountDialog extends StatefulWidget {
  const _PjsipAccountDialog();

  @override
  State<_PjsipAccountDialog> createState() => _PjsipAccountDialogState();
}

class _PjsipAccountDialogState extends State<_PjsipAccountDialog> {
  late final TextEditingController usernameController;
  late final TextEditingController authUsernameController;
  late final TextEditingController passwordController;
  late final TextEditingController hostController;
  late final TextEditingController portController;
  late final TextEditingController stunServerController;
  late final TextEditingController stunPortController;
  String transport = 'udp';
  PjsipMediaSecurity mediaSecurity = PjsipMediaSecurity.none;
  bool obscurePassword = true;
  bool stunEnabled = false;
  bool iceEnabled = false;
  bool tlsVerifyServer = false;
  String errorMessage = '';

  @override
  void initState() {
    super.initState();
    final debugAccount = createDebugTestAccount();
    usernameController =
        TextEditingController(text: debugAccount?.username ?? '');
    authUsernameController = TextEditingController();
    passwordController =
        TextEditingController(text: debugAccount?.password ?? '');
    hostController = TextEditingController(text: debugAccount?.host ?? '');
    portController = TextEditingController(text: '5060');
    stunServerController = TextEditingController(text: 'stun.l.google.com');
    stunPortController = TextEditingController(text: '19302');
  }

  @override
  void dispose() {
    usernameController.dispose();
    authUsernameController.dispose();
    passwordController.dispose();
    hostController.dispose();
    portController.dispose();
    stunServerController.dispose();
    stunPortController.dispose();
    super.dispose();
  }

  void changeTransport(String value) {
    final oldDefault = transport == 'tls' ? 5061 : 5060;
    final currentPort = int.tryParse(portController.text);
    setState(() {
      transport = value;
      if (currentPort == null || currentPort == oldDefault) {
        portController.text = value == 'tls' ? '5061' : '5060';
      }
      if (value == 'tls' && mediaSecurity == PjsipMediaSecurity.none) {
        mediaSecurity = PjsipMediaSecurity.dtlsSrtp;
      }
    });
  }

  void submit() {
    final username = usernameController.text.trim();
    final password = passwordController.text;
    final host = hostController.text.trim();
    final port = int.tryParse(portController.text.trim());
    final stunServer = stunServerController.text.trim();
    final stunPort = int.tryParse(stunPortController.text.trim());
    if (username.isEmpty || password.isEmpty || host.isEmpty) {
      setState(() => errorMessage = '请填写账号、密码和 SIP 服务器');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => errorMessage = 'SIP 端口必须在 1 到 65535 之间');
      return;
    }
    if (stunEnabled && stunServer.isEmpty) {
      setState(() => errorMessage = '启用 STUN 后必须填写 STUN 服务器');
      return;
    }
    if (stunEnabled &&
        (stunPort == null || stunPort < 1 || stunPort > 65535)) {
      setState(() => errorMessage = 'STUN 端口必须在 1 到 65535 之间');
      return;
    }
    Navigator.of(context).pop(
      PjsipAccountConfig(
        username: username,
        authUsername: authUsernameController.text.trim(),
        password: password,
        host: host,
        transport: transport,
        port: port,
        mediaSecurity: mediaSecurity,
        stunEnabled: stunEnabled,
        stunServer: stunServer,
        stunPort: stunPort ?? 3478,
        iceEnabled: iceEnabled,
        tlsVerifyServer: tlsVerifyServer,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.person_add_alt_1, color: Color(0xff006d5b)),
          SizedBox(width: 10),
          Text('添加 SIP 账号'),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('账号信息',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'SIP 账号',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: authUsernameController,
                      decoration: const InputDecoration(
                        labelText: '认证账号（可选）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                decoration: InputDecoration(
                  labelText: '密码',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: () => setState(
                      () => obscurePassword = !obscurePassword,
                    ),
                    icon: Icon(obscurePassword
                        ? Icons.visibility
                        : Icons.visibility_off),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('连接与安全',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: hostController,
                      decoration: const InputDecoration(
                        labelText: 'SIP 服务器',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 105,
                    child: TextField(
                      controller: portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 125,
                    child: DropdownButtonFormField<String>(
                      initialValue: transport,
                      decoration: const InputDecoration(
                        labelText: '信令传输',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'udp', child: Text('UDP')),
                        DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                        DropdownMenuItem(value: 'tls', child: Text('TLS')),
                      ],
                      onChanged: (value) {
                        if (value != null) changeTransport(value);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PjsipMediaSecurity>(
                key: ValueKey<PjsipMediaSecurity>(mediaSecurity),
                initialValue: mediaSecurity,
                decoration: const InputDecoration(
                  labelText: '媒体安全',
                  helperText: 'TLS 保护 SIP 信令；SRTP/DTLS-SRTP 保护语音媒体',
                  border: OutlineInputBorder(),
                ),
                items: PjsipMediaSecurity.values
                    .map((mode) => DropdownMenuItem(
                          value: mode,
                          child: Text(mode.label),
                        ))
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => mediaSecurity = value);
                },
              ),
              if (transport == 'tls') ...[
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('验证服务端 TLS 证书'),
                  subtitle: Text(
                    tlsVerifyServer
                        ? '使用系统信任链验证证书，服务器地址需匹配证书域名'
                        : '已关闭：兼容自签名证书，仅建议用于测试或可信网络',
                  ),
                  value: tlsVerifyServer,
                  onChanged: (value) =>
                      setState(() => tlsVerifyServer = value),
                ),
              ],
              const SizedBox(height: 20),
              const Text('网络与 NAT',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 STUN'),
                subtitle: const Text('探测公网映射地址，可独立于 ICE 使用'),
                value: stunEnabled,
                onChanged: (value) => setState(() => stunEnabled = value),
              ),
              if (stunEnabled) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: stunServerController,
                        decoration: const InputDecoration(
                          labelText: 'STUN 服务器',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: stunPortController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'STUN 端口',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 ICE'),
                subtitle: const Text('为通话媒体收集并检查可用网络候选地址'),
                value: iceEnabled,
                onChanged: (value) => setState(() => iceEnabled = value),
              ),
              if (iceEnabled && transport == 'udp')
                const Text(
                  'UDP + ICE 会增大 SDP；网络不支持 UDP 分片时建议改用 TCP/TLS。',
                  style: TextStyle(color: Color(0xff9a6700)),
                ),
              if (errorMessage.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(errorMessage,
                    style: const TextStyle(color: Color(0xffb42318))),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: submit,
          icon: const Icon(Icons.add),
          label: const Text('添加并注册'),
        ),
      ],
    );
  }
}
