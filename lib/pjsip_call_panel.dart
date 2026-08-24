import 'dart:async';

import 'package:flutter/material.dart';

import 'pjsip_native_bridge.dart';

class PjsipCallPanel extends StatefulWidget {
  const PjsipCallPanel({super.key, required this.bridge});

  final PjsipNativeBridge bridge;

  @override
  State<PjsipCallPanel> createState() => _PjsipCallPanelState();
}

class _PjsipCallPanelState extends State<PjsipCallPanel> {
  final destinationController = TextEditingController();
  StreamSubscription<PjsipCallEvent>? subscription;
  PjsipCallEvent? call;
  String operationMessage = '注册账号后可拨打号码';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    call = widget.bridge.currentCall;
    subscription = widget.bridge.callStream.listen((event) {
      if (!mounted) return;
      setState(() {
        call = event;
        operationMessage = event.message.isEmpty
            ? _stateLabel(event.state)
            : event.message;
      });
    });
  }

  Future<void> _operate(Future<PjsipOperationResult> Function() action) async {
    setState(() => busy = true);
    try {
      final result = await action();
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _dial() {
    final destination = destinationController.text.trim();
    if (destination.isEmpty) {
      setState(() => operationMessage = '请输入号码或 SIP URI');
      return;
    }
    unawaited(_operate(() => widget.bridge.makeCall(destination)));
  }

  @override
  void dispose() {
    subscription?.cancel();
    destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = call;
    final active = current?.isActive ?? false;
    final incoming = current?.canAnswer ?? false;
    final color = current?.isConnected == true
        ? const Color(0xff007a5e)
        : incoming
            ? const Color(0xffb54708)
            : const Color(0xff315c70);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(incoming ? Icons.call_received : Icons.call,
                    size: 18, color: color),
                const SizedBox(width: 8),
                Text(
                  current == null
                      ? '语音通话'
                      : _stateLabel(current.state),
                  style: TextStyle(fontWeight: FontWeight.w700, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    current?.remoteUri ?? operationMessage,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (current != null) Text('Call ${current.callId}'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: destinationController,
                    enabled: !busy && !active,
                    onSubmitted: (_) => _dial(),
                    decoration: const InputDecoration(
                      labelText: '号码或 SIP URI',
                      hintText: '例如 1001',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.dialpad),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: busy || active ? null : _dial,
                  icon: const Icon(Icons.call),
                  label: const Text('呼叫'),
                ),
                if (incoming) ...[
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => unawaited(_operate(
                              () => widget.bridge.answerCall(current!.callId),
                            )),
                    icon: const Icon(Icons.call),
                    label: const Text('接听'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => unawaited(_operate(
                              () => widget.bridge.rejectCall(current!.callId),
                            )),
                    child: const Text('拒接'),
                  ),
                ],
                if (active && !incoming) ...[
                  const SizedBox(width: 10),
                  FilledButton.tonalIcon(
                    onPressed: busy
                        ? null
                        : () => unawaited(_operate(
                              () => widget.bridge.hangupCall(current!.callId),
                            )),
                    icon: const Icon(Icons.call_end),
                    label: const Text('挂断'),
                  ),
                ],
                if (busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _stateLabel(PjsipCallState state) {
    switch (state) {
      case PjsipCallState.calling:
        return '正在呼叫';
      case PjsipCallState.incoming:
        return '收到来电';
      case PjsipCallState.early:
        return '对方振铃';
      case PjsipCallState.connecting:
        return '正在连接';
      case PjsipCallState.confirmed:
        return '通话中';
      case PjsipCallState.disconnected:
        return '通话已结束';
      case PjsipCallState.idle:
        return '空闲';
      case PjsipCallState.unknown:
        return '未知状态';
    }
  }
}
