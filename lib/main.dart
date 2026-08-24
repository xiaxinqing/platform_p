import 'dart:async';

import 'package:flutter/material.dart';

import 'pjsip_account_panel.dart';
import 'pjsip_call_panel.dart';
import 'pjsip_debug_account.dart';
import 'pjsip_native_bridge.dart';

void main() => runApp(const PlatformPApp());

class PlatformPApp extends StatelessWidget {
  const PlatformPApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PJSIP Native Console',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff006d5b)),
        scaffoldBackgroundColor: const Color(0xfff2eee4),
        useMaterial3: true,
      ),
      home: const PjsipConsolePage(),
    );
  }
}

class PjsipConsolePage extends StatefulWidget {
  const PjsipConsolePage({super.key});

  @override
  State<PjsipConsolePage> createState() => _PjsipConsolePageState();
}

class _PjsipConsolePageState extends State<PjsipConsolePage> {
  final bridge = PjsipNativeBridge.instance;
  final logs = <String>[];
  StreamSubscription<PjsipStatusEvent>? statusSubscription;
  StreamSubscription<PjsipLogEvent>? logSubscription;
  PjsipLifecycleState lifecycle = PjsipLifecycleState.initializing;
  String summary = '正在等待原生 PJSIP 初始化';
  bool busy = true;

  @override
  void initState() {
    super.initState();
    statusSubscription = bridge.statusStream.listen(_onStatus);
    logSubscription = bridge.logStream.listen(_onLog);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    setState(() => busy = true);
    try {
      final result = await bridge.initialize();
      if (!mounted) return;
      setState(() {
        lifecycle = result.state;
        summary = result.message;
      });
      const autoRegister =
          bool.fromEnvironment('PJSIP_AUTO_REGISTER', defaultValue: false);
      final debugAccount = autoRegister ? createDebugTestAccount() : null;
      if (debugAccount != null) {
        await bridge.registerAccount(debugAccount);
      }
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() {
        lifecycle = PjsipLifecycleState.error;
        summary = error.code + ': ' + error.message;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _onStatus(PjsipStatusEvent event) {
    if (!mounted) return;
    setState(() {
      lifecycle = event.state;
      summary = event.message;
    });
  }

  void _onLog(PjsipLogEvent event) {
    if (!mounted) return;
    setState(() {
      logs.add('[L' + event.level.toString() + '] ' + event.message);
      if (logs.length > 300) logs.removeRange(0, logs.length - 300);
    });
  }

  Future<void> _status() async {
    final result = await bridge.status();
    if (!mounted) return;
    setState(() {
      lifecycle = result.state;
      summary = result.message;
    });
  }

  Future<void> _shutdown() async {
    final result = await bridge.shutdown();
    if (!mounted) return;
    setState(() {
      lifecycle = result.state;
      summary = result.message;
    });
  }

  @override
  void dispose() {
    statusSubscription?.cancel();
    logSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = lifecycle == PjsipLifecycleState.started
        ? const Color(0xff007a5e)
        : lifecycle == PjsipLifecycleState.error
            ? const Color(0xffb42318)
            : const Color(0xff9a6700);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('PJSIP NATIVE',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.4,
                      color: Color(0xff006d5b))),
              const SizedBox(height: 8),
              const Text('桌面原生引擎控制台',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 14, color: color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(lifecycle.name.toUpperCase(),
                                style: TextStyle(
                                    color: color, fontWeight: FontWeight.w800)),
                            Text(summary),
                          ],
                        ),
                      ),
                      if (busy)
                        const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
              ),
              Wrap(
                spacing: 10,
                children: [
                  FilledButton(onPressed: busy ? null : _initialize, child: const Text('初始化')),
                  OutlinedButton(onPressed: _status, child: const Text('查询状态')),
                  OutlinedButton(onPressed: _shutdown, child: const Text('关闭引擎')),
                ],
              ),
              const SizedBox(height: 12),
              PjsipAccountPanel(bridge: bridge),
              const SizedBox(height: 12),
              PjsipCallPanel(bridge: bridge),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: const Color(0xff17211f),
                      borderRadius: BorderRadius.circular(14)),
                  child: logs.isEmpty
                      ? const Text('等待 PJSIP 日志...',
                          style: TextStyle(color: Color(0xffa8bbb6)))
                      : ListView.builder(
                          reverse: true,
                          itemCount: logs.length,
                          itemBuilder: (context, index) => SelectableText(
                            logs[logs.length - index - 1],
                            style: const TextStyle(
                                color: Color(0xffd8e8e3),
                                fontFamily: 'Menlo',
                                fontSize: 12,
                                height: 1.35),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
