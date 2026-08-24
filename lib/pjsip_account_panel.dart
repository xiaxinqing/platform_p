import 'dart:async';

import 'package:flutter/material.dart';

import 'pjsip_debug_account.dart';
import 'pjsip_native_bridge.dart';

class PjsipAccountPanel extends StatefulWidget {
  const PjsipAccountPanel({super.key, required this.bridge});

  final PjsipNativeBridge bridge;

  @override
  State<PjsipAccountPanel> createState() => _PjsipAccountPanelState();
}

class _PjsipAccountPanelState extends State<PjsipAccountPanel> {
  late final TextEditingController usernameController;
  late final TextEditingController passwordController;
  late final TextEditingController hostController;
  StreamSubscription<PjsipRegistrationEvent>? subscription;
  PjsipRegistrationEvent? registration;
  String transport = 'udp';
  String operationMessage = '尚未注册 SIP 账号';
  bool busy = false;
  bool obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final debugAccount = createDebugTestAccount();
    usernameController =
        TextEditingController(text: debugAccount?.username ?? '');
    passwordController =
        TextEditingController(text: debugAccount?.password ?? '');
    hostController = TextEditingController(text: debugAccount?.host ?? '');
    registration = widget.bridge.currentRegistration;
    subscription = widget.bridge.registrationStream.listen((event) {
      if (!mounted) return;
      setState(() {
        registration = event;
        operationMessage = event.message;
      });
    });
  }

  Future<void> register() async {
    final username = usernameController.text.trim();
    final password = passwordController.text;
    final host = hostController.text.trim();
    if (username.isEmpty || password.isEmpty || host.isEmpty) {
      setState(() => operationMessage = '请填写账号、密码和服务器');
      return;
    }
    setState(() {
      busy = true;
      operationMessage = '正在发送注册请求';
    });
    try {
      final result = await widget.bridge.registerAccount(
        PjsipAccountConfig(
          username: username,
          password: password,
          host: host,
          transport: transport,
        ),
      );
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> unregister() async {
    setState(() {
      busy = true;
      operationMessage = '正在注销账号';
    });
    try {
      final result = await widget.bridge.unregisterAccount();
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    usernameController.dispose();
    passwordController.dispose();
    hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registered = registration?.registered ?? false;
    final statusColor =
        registered ? const Color(0xff007a5e) : const Color(0xff9a6700);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: statusColor),
                const SizedBox(width: 8),
                Text(
                  registered ? '账号已注册' : 'SIP 测试账号',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  registration == null
                      ? ''
                      : 'SIP ' + registration!.status.toString(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () => setState(
                          () => obscurePassword = !obscurePassword,
                        ),
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 210,
                  child: TextField(
                    controller: hostController,
                    decoration: const InputDecoration(
                      labelText: 'SIP 服务器',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: DropdownButtonFormField<String>(
                    initialValue: transport,
                    decoration: const InputDecoration(
                      labelText: '传输',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'udp', child: Text('UDP')),
                      DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(
                              () => transport = value ?? transport,
                            ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: busy || registered ? null : register,
                  child: const Text('注册账号'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: busy ? null : unregister,
                  child: const Text('注销账号'),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(operationMessage)),
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
