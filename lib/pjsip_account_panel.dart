import 'dart:async';

import 'package:flutter/material.dart';

import 'pjsip_account_dialog.dart';
import 'pjsip_native_bridge.dart';

class PjsipAccountPanel extends StatefulWidget {
  const PjsipAccountPanel({super.key, required this.bridge});

  final PjsipNativeBridge bridge;

  @override
  State<PjsipAccountPanel> createState() => _PjsipAccountPanelState();
}

class _PjsipAccountPanelState extends State<PjsipAccountPanel> {
  StreamSubscription<PjsipRegistrationEvent>? subscription;
  String operationMessage = '可同时添加多个 SIP 账号';
  final Set<int> busyAccountIds = <int>{};
  bool adding = false;

  @override
  void initState() {
    super.initState();
    subscription = widget.bridge.registrationStream.listen((event) {
      if (!mounted) return;
      setState(() => operationMessage = event.message);
    });
  }

  Future<void> addAccount() async {
    final config = await showPjsipAccountDialog(context);
    if (config == null || !mounted) return;
    setState(() {
      adding = true;
      operationMessage = '正在添加账号 ${config.username}';
    });
    try {
      final result = await widget.bridge.registerAccount(config);
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => adding = false);
    }
  }

  Future<void> unregister(int accountId) async {
    setState(() {
      busyAccountIds.add(accountId);
      operationMessage = '正在注销账号 $accountId';
    });
    try {
      final result = await widget.bridge.unregisterAccount(accountId);
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) {
        setState(() => busyAccountIds.remove(accountId));
      }
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = widget.bridge.currentRegistrations.values.toList()
      ..sort((a, b) => a.accountId.compareTo(b.accountId));
    final configs = widget.bridge.currentAccountConfigs;
    final onlineCount = accounts.where((item) => item.registered).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.hub_outlined, color: Color(0xff006d5b)),
                const SizedBox(width: 8),
                const Text(
                  'SIP 账号管理',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 12),
                Text('$onlineCount 在线 / ${accounts.length} 个账号'),
                const Spacer(),
                FilledButton.icon(
                  onPressed: adding ? null : addAccount,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('添加账号'),
                ),
                if (adding) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            if (operationMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(operationMessage),
            ],
            if (accounts.isEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xff006d5b).withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('尚未添加账号，点击右上角“添加账号”开始配置。'),
              ),
            ] else ...[
              const Divider(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: accounts.map((account) {
                  final config = configs[account.accountId];
                  final color = account.registered
                      ? const Color(0xff007a5e)
                      : account.state == PjsipRegistrationState.failed
                          ? const Color(0xffb42318)
                          : const Color(0xff9a6700);
                  final busy = busyAccountIds.contains(account.accountId);
                  final transport = config?.transport.toUpperCase() ?? 'SIP';
                  final port = config?.port ?? 0;
                  final security =
                      config?.mediaSecurity.label ?? PjsipMediaSecurity.none.label;
                  final natFeatures = <String>[
                    if (config?.stunEnabled == true) 'STUN',
                    if (config?.iceEnabled == true) 'ICE',
                  ];
                  final natLabel = natFeatures.isEmpty
                      ? ''
                      : ' · ${natFeatures.join('+')}';
                  final tlsLabel = config?.transport == 'tls'
                      ? config?.tlsVerifyServer == true
                          ? ' · 校验证书'
                          : ' · 不校验证书'
                      : '';
                  return Container(
                    width: 350,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.07),
                      border: Border.all(color: color.withValues(alpha: 0.35)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.circle, size: 11, color: color),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                account.accountUri.isEmpty
                                    ? 'Account ${account.accountId}'
                                    : account.accountUri,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                account.registered
                                    ? '已注册 · $transport:${port == 0 ? '-' : port} · $security$natLabel$tlsLabel'
                                    : account.message,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '注销并移除',
                          onPressed:
                              busy ? null : () => unregister(account.accountId),
                          icon: busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.logout),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
