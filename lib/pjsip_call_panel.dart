import 'dart:async';
import 'dart:math' as math;

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
  StreamSubscription<PjsipCallEvent>? callSubscription;
  StreamSubscription<PjsipRegistrationEvent>? registrationSubscription;
  Timer? durationTimer;
  Timer? audioLevelTimer;
  final Set<int> busyCallIds = <int>{};
  final Map<int, DateTime> connectedAt = <int, DateTime>{};
  String operationMessage = '注册账号后可拨打号码';
  bool dialing = false;
  bool audioControlBusy = false;
  bool audioLevelRequestInFlight = false;
  bool microphoneMuted = false;
  bool speakerMuted = false;
  int? audioLevelCallId;
  double microphoneLevel = 0;
  double remoteLevel = 0;
  int? selectedAccountId;

  @override
  void initState() {
    super.initState();
    final onlineAccounts = widget.bridge.currentRegistrations.values
        .where((account) => account.registered)
        .toList();
    selectedAccountId =
        onlineAccounts.isEmpty ? null : onlineAccounts.first.accountId;
    for (final call in widget.bridge.currentCalls.values) {
      if (call.isConnected) connectedAt[call.callId] = DateTime.now();
    }
    durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && connectedAt.isNotEmpty) setState(() {});
    });
    audioLevelTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_pollAudioLevels()),
    );
    callSubscription = widget.bridge.callStream.listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.isConnected) {
          connectedAt.putIfAbsent(event.callId, DateTime.now);
        }
        if (event.state == PjsipCallState.disconnected ||
            event.state == PjsipCallState.idle) {
          connectedAt.remove(event.callId);
        }
        operationMessage =
            event.message.isEmpty ? _stateLabel(event.state) : event.message;
      });
    });
    registrationSubscription = widget.bridge.registrationStream.listen((_) {
      if (!mounted) return;
      final ids = widget.bridge.currentRegistrations.values
          .where((account) => account.registered)
          .map((account) => account.accountId)
          .toList();
      setState(() {
        if (!ids.contains(selectedAccountId)) {
          selectedAccountId = ids.isEmpty ? null : ids.first;
        }
      });
    });
  }

  Future<void> _dial() async {
    final destination = destinationController.text.trim();
    final accountId = selectedAccountId;
    if (destination.isEmpty) {
      setState(() => operationMessage = '请输入号码或 SIP URI');
      return;
    }
    if (accountId == null) {
      setState(() => operationMessage = '请先注册并选择一个外呼账号');
      return;
    }
    setState(() {
      dialing = true;
      operationMessage = '正在发起呼叫';
    });
    try {
      final result = await widget.bridge.makeCall(destination, accountId);
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => dialing = false);
    }
  }

  Future<void> _control(
    int callId,
    Future<PjsipOperationResult> Function() action,
  ) async {
    setState(() => busyCallIds.add(callId));
    try {
      final result = await action();
      if (!mounted) return;
      setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (!mounted) return;
      setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => busyCallIds.remove(callId));
    }
  }

  Future<void> _setMicrophoneMuted(bool muted) async {
    setState(() => audioControlBusy = true);
    try {
      final result = await widget.bridge.setMicrophoneMuted(muted);
      if (!mounted) return;
      setState(() {
        microphoneMuted = muted;
        if (muted) microphoneLevel = 0;
        operationMessage = result.message;
      });
    } on PjsipBridgeException catch (error) {
      if (mounted) setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => audioControlBusy = false);
    }
  }

  Future<void> _setSpeakerMuted(bool muted) async {
    setState(() => audioControlBusy = true);
    try {
      final result = await widget.bridge.setSpeakerMuted(muted);
      if (!mounted) return;
      setState(() {
        speakerMuted = muted;
        if (muted) remoteLevel = 0;
        operationMessage = result.message;
      });
    } on PjsipBridgeException catch (error) {
      if (mounted) setState(() => operationMessage = error.message);
    } finally {
      if (mounted) setState(() => audioControlBusy = false);
    }
  }

  Future<void> _sendDtmf(int callId, String digit) async {
    try {
      final result = await widget.bridge.sendDtmf(callId, digit);
      if (mounted) setState(() => operationMessage = result.message);
    } on PjsipBridgeException catch (error) {
      if (mounted) setState(() => operationMessage = error.message);
    }
  }

  Future<void> _pollAudioLevels() async {
    if (!mounted || audioLevelRequestInFlight) return;
    final activeCalls = widget.bridge.currentCalls.values
        .where((call) => call.isConnected && !call.isOnHold)
        .toList()
      ..sort((a, b) => a.callId.compareTo(b.callId));
    if (activeCalls.isEmpty) {
      if (audioLevelCallId != null ||
          microphoneLevel != 0 ||
          remoteLevel != 0) {
        setState(() {
          audioLevelCallId = null;
          microphoneLevel = 0;
          remoteLevel = 0;
        });
      }
      return;
    }

    final call = activeCalls.first;
    audioLevelRequestInFlight = true;
    try {
      final levels = await widget.bridge.getAudioLevels(call.callId);
      if (!mounted) return;
      final microphoneTarget = levels.success && !microphoneMuted
          ? levels.microphoneLevel / 255.0
          : 0.0;
      final remoteTarget = levels.success && !speakerMuted
          ? levels.remoteLevel / 255.0
          : 0.0;
      setState(() {
        if (audioLevelCallId != call.callId) {
          microphoneLevel = 0;
          remoteLevel = 0;
        }
        audioLevelCallId = call.callId;
        microphoneLevel = _smoothLevel(microphoneLevel, microphoneTarget);
        remoteLevel = _smoothLevel(remoteLevel, remoteTarget);
      });
    } on PjsipBridgeException {
      if (mounted && audioLevelCallId == call.callId) {
        setState(() {
          microphoneLevel = _smoothLevel(microphoneLevel, 0);
          remoteLevel = _smoothLevel(remoteLevel, 0);
        });
      }
    } finally {
      audioLevelRequestInFlight = false;
    }
  }

  double _smoothLevel(double current, double target) {
    final factor = target > current ? 0.55 : 0.25;
    return current + (target - current) * factor;
  }

  void _showDtmfPad(PjsipCallEvent call) {
    showDialog<void>(
      context: context,
      builder: (context) => _DtmfPad(
        remoteUri: call.remoteUri,
        onDigit: (digit) => _sendDtmf(call.callId, digit),
      ),
    );
  }

  Future<void> _showBlindTransfer(PjsipCallEvent call) async {
    final destination = await showDialog<String>(
      context: context,
      builder: (context) => _BlindTransferDialog(remoteUri: call.remoteUri),
    );
    if (!mounted || destination == null) return;
    await _control(
      call.callId,
      () => widget.bridge.transferCall(call.callId, destination),
    );
  }

  void _showCallSettings() {
    showDialog<void>(
      context: context,
      builder: (context) => _CallSettingsDialog(bridge: widget.bridge),
    );
  }

  @override
  void dispose() {
    durationTimer?.cancel();
    audioLevelTimer?.cancel();
    callSubscription?.cancel();
    registrationSubscription?.cancel();
    destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onlineAccounts = widget.bridge.currentRegistrations.values
        .where((account) => account.registered)
        .toList()
      ..sort((a, b) => a.accountId.compareTo(b.accountId));
    final calls = widget.bridge.currentCalls.values.toList()
      ..sort((a, b) => a.callId.compareTo(b.callId));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.call, size: 18, color: Color(0xff006d5b)),
                const SizedBox(width: 8),
                const Text(
                  '语音通话',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    operationMessage,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('${calls.length} / 4 路'),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '通话设定',
                  onPressed: _showCallSettings,
                  icon: const Icon(Icons.tune, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<int>(
                    key: ValueKey<int?>(selectedAccountId),
                    isExpanded: true,
                    initialValue: onlineAccounts.any(
                            (item) => item.accountId == selectedAccountId)
                        ? selectedAccountId
                        : null,
                    decoration: const InputDecoration(
                      labelText: '外呼账号',
                      border: OutlineInputBorder(),
                    ),
                    items: onlineAccounts
                        .map(
                          (account) => DropdownMenuItem<int>(
                            value: account.accountId,
                            child: Text(
                              account.accountUri.isEmpty
                                  ? 'Account ${account.accountId}'
                                  : account.accountUri,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: dialing
                        ? null
                        : (value) => setState(() => selectedAccountId = value),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: destinationController,
                    enabled: !dialing && calls.length < 4,
                    onSubmitted: (_) => unawaited(_dial()),
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
                  onPressed: dialing || calls.length >= 4 ? null : _dial,
                  icon: const Icon(Icons.call),
                  label: const Text('呼叫'),
                ),
                if (dialing) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            if (calls.isEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                '当前没有通话。新来电和外呼会显示为独立卡片。',
                style: TextStyle(color: Color(0xff52635f)),
              ),
            ] else ...[
              const Divider(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: calls.map(_buildCallCard).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCallCard(PjsipCallEvent call) {
    final incoming = call.canAnswer;
    final busy = busyCallIds.contains(call.callId);
    final color = call.isConnected
        ? call.isOnHold
            ? const Color(0xff9a6700)
            : const Color(0xff007a5e)
        : incoming
            ? const Color(0xffb54708)
            : const Color(0xff315c70);
    return Container(
      width: 365,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                call.incoming ? Icons.call_received : Icons.call_made,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  call.remoteUri,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text('#${call.callId}'),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${_stateLabel(call.state)} · 账号 ${call.accountId}'
                  '${call.isOnHold ? ' · 保持中' : ''}'
                  '${call.isConnected ? ' · ${_duration(call.callId)}' : ''}',
                  style: TextStyle(color: color),
                ),
              ),
              const SizedBox(width: 8),
              _CallSecurityBadge(call: call),
            ],
          ),
          if (call.isConnected && !call.isOnHold) ...[
            const SizedBox(height: 10),
            _AudioLevelBar(
              label: '麦克风',
              icon: microphoneMuted ? Icons.mic_off : Icons.mic,
              level: audioLevelCallId == call.callId ? microphoneLevel : 0,
              muted: microphoneMuted,
              color: const Color(0xff00856a),
            ),
            const SizedBox(height: 7),
            _AudioLevelBar(
              label: '远端声音',
              icon: speakerMuted ? Icons.volume_off : Icons.graphic_eq,
              level: audioLevelCallId == call.callId ? remoteLevel : 0,
              muted: speakerMuted,
              color: const Color(0xff315c70),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (incoming)
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => unawaited(
                            _control(
                              call.callId,
                              () => widget.bridge.answerCall(call.callId),
                            ),
                          ),
                  icon: const Icon(Icons.call),
                  label: const Text('接听'),
                ),
              if (incoming)
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => unawaited(
                            _control(
                              call.callId,
                              () => widget.bridge.rejectCall(call.callId),
                            ),
                          ),
                  child: const Text('拒接'),
                ),
              if (call.isConnected && !call.isOnHold)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => unawaited(
                            _control(
                              call.callId,
                              () => widget.bridge.holdCall(call.callId),
                            ),
                          ),
                  icon: const Icon(Icons.pause),
                  label: const Text('保持'),
                ),
              if (call.isConnected && !call.isOnHold)
                OutlinedButton.icon(
                  onPressed: audioControlBusy
                      ? null
                      : () => unawaited(
                            _setMicrophoneMuted(!microphoneMuted),
                          ),
                  icon: Icon(microphoneMuted ? Icons.mic_off : Icons.mic),
                  label: Text(microphoneMuted ? '取消静音' : '麦克风静音'),
                ),
              if (call.isConnected && !call.isOnHold)
                OutlinedButton.icon(
                  onPressed: audioControlBusy
                      ? null
                      : () => unawaited(_setSpeakerMuted(!speakerMuted)),
                  icon: Icon(
                    speakerMuted ? Icons.volume_off : Icons.volume_up,
                  ),
                  label: Text(speakerMuted ? '恢复声音' : '不听对方'),
                ),
              if (call.isConnected && !call.isOnHold)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _showDtmfPad(call),
                  icon: const Icon(Icons.dialpad),
                  label: const Text('拨号键盘'),
                ),
              if (call.isConnected)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => unawaited(_showBlindTransfer(call)),
                  icon: const Icon(Icons.phone_forwarded),
                  label: const Text('转接'),
                ),
              if (call.isConnected && call.isOnHold)
                FilledButton.tonalIcon(
                  onPressed: busy
                      ? null
                      : () => unawaited(
                            _control(
                              call.callId,
                              () => widget.bridge.resumeCall(call.callId),
                            ),
                          ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('恢复'),
                ),
              if (!incoming)
                FilledButton.tonalIcon(
                  onPressed: busy
                      ? null
                      : () => unawaited(
                            _control(
                              call.callId,
                              () => widget.bridge.hangupCall(call.callId),
                            ),
                          ),
                  icon: const Icon(Icons.call_end),
                  label: const Text('挂断'),
                ),
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
    );
  }

  String _stateLabel(PjsipCallState state) {
    switch (state) {
      case PjsipCallState.calling:
        return '正在呼叫';
      case PjsipCallState.incoming:
        return '收到来电';
      case PjsipCallState.early:
        return '振铃中';
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

  String _duration(int callId) {
    final startedAt = connectedAt[callId];
    if (startedAt == null) return '00:00';
    final elapsed = DateTime.now().difference(startedAt);
    final hours = elapsed.inHours;
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _CallSecurityBadge extends StatelessWidget {
  const _CallSecurityBadge({required this.call});

  final PjsipCallEvent call;

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    late final Color color;
    late final String label;
    switch (call.securityState) {
      case PjsipMediaSecurityState.secure:
        icon = Icons.lock;
        color = const Color(0xff007a5e);
        label = switch (call.mediaSecurity) {
          'dtls' => 'DTLS-SRTP',
          'sdes' => 'SDES-SRTP',
          _ => 'SRTP',
        };
      case PjsipMediaSecurityState.negotiating:
        icon = Icons.lock_outline;
        color = const Color(0xff9a6700);
        label = '加密协商中';
      case PjsipMediaSecurityState.failed:
        icon = Icons.lock_open;
        color = const Color(0xffb42318);
        label = '加密失败';
      case PjsipMediaSecurityState.insecure:
        icon = Icons.lock_open;
        color = const Color(0xff52635f);
        label = '普通 RTP';
      case PjsipMediaSecurityState.unknown:
        icon = Icons.lock_outline;
        color = const Color(0xff52635f);
        label = '检测中';
    }
    final signaling = call.signalingTransport.isEmpty
        ? '未知'
        : call.signalingTransport.toUpperCase();
    final suite = call.cryptoSuite.isEmpty
        ? ''
        : '\n加密套件：${call.cryptoSuite}';
    return Tooltip(
      message: '信令：$signaling\n媒体：$label$suite',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.32)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioLevelBar extends StatefulWidget {
  const _AudioLevelBar({
    required this.label,
    required this.icon,
    required this.level,
    required this.muted,
    required this.color,
  });

  final String label;
  final IconData icon;
  final double level;
  final bool muted;
  final Color color;

  @override
  State<_AudioLevelBar> createState() => _AudioLevelBarState();
}

class _AudioLevelBarState extends State<_AudioLevelBar> {
  static const noiseFloor = 0.075;
  static const visualPower = 0.72;
  static const visibleFloor = 0.08;
  static const riseDuration = Duration(milliseconds: 70);
  static const fallDuration = Duration(milliseconds: 320);

  double previousTarget = 0;
  double peakTarget = 0;
  Duration animationDuration = riseDuration;

  double _displayValue() {
    if (widget.muted) return 0;
    final raw = widget.level.clamp(0.0, 1.0).toDouble();
    if (raw <= noiseFloor) return 0;
    final gated = ((raw - noiseFloor) / (1 - noiseFloor))
        .clamp(0.0, 1.0)
        .toDouble();
    final value = math
        .pow(gated, visualPower)
        .toDouble()
        .clamp(0.0, 1.0)
        .toDouble();
    return value < visibleFloor ? 0 : value;
  }

  @override
  void didUpdateWidget(_AudioLevelBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _displayValue();
    animationDuration =
        target >= previousTarget ? riseDuration : fallDuration;
    peakTarget = target >= peakTarget
        ? target
        : math.max(target, peakTarget - 0.045);
    previousTarget = target;
  }

  @override
  Widget build(BuildContext context) {
    final target = _displayValue();
    final effectiveColor =
        widget.muted ? const Color(0xff87938f) : widget.color;
    return Row(
      children: [
        Icon(widget.icon, size: 17, color: effectiveColor),
        const SizedBox(width: 8),
        SizedBox(
          width: 70,
          child: Text(
            widget.label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: target),
            duration: animationDuration,
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, _) => _SegmentedLevelMeter(
              value: animatedValue,
              peakValue: peakTarget,
              color: effectiveColor,
              muted: widget.muted,
              label: widget.label,
            ),
          ),
        ),
      ],
    );
  }
}

class _SegmentedLevelMeter extends StatelessWidget {
  const _SegmentedLevelMeter({
    required this.value,
    required this.peakValue,
    required this.color,
    required this.muted,
    required this.label,
  });

  final double value;
  final double peakValue;
  final Color color;
  final bool muted;
  final String label;

  @override
  Widget build(BuildContext context) {
    const segmentCount = 26;
    const gap = 2.5;
    final activeValue = muted ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    final activePeak = muted ? 0.0 : peakValue.clamp(0.0, 1.0).toDouble();
    final litSegments = activeValue <= 0
        ? 0
        : (activeValue * segmentCount).floor().clamp(1, segmentCount).toInt();
    final peakSegment = activePeak <= 0
        ? -1
        : ((activePeak * segmentCount).ceil() - 1)
            .clamp(0, segmentCount - 1)
            .toInt();
    final trackColor = Color.lerp(
      Theme.of(context).colorScheme.surface,
      const Color(0xff6f7d79),
      0.24,
    )!;

    return Tooltip(
      message: muted
          ? '$label：已静音'
          : '$label：当前 ${(activeValue * 100).round()}%，峰值 ${(activePeak * 100).round()}%',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math
              .max(
                3.0,
                (constraints.maxWidth - gap * (segmentCount - 1)) /
                    segmentCount,
              )
              .clamp(3.0, 9.0)
              .toDouble();
          return Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < segmentCount; index++) ...[
                  _LevelSegment(
                    active: index < litSegments,
                    peak: index == peakSegment && activePeak > 0.12,
                    color: color,
                    trackColor: trackColor,
                    width: width,
                  ),
                  if (index != segmentCount - 1)
                    const SizedBox(width: gap),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LevelSegment extends StatelessWidget {
  const _LevelSegment({
    required this.active,
    required this.peak,
    required this.color,
    required this.trackColor,
    required this.width,
  });

  final bool active;
  final bool peak;
  final Color color;
  final Color trackColor;
  final double width;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: active
          ? const Duration(milliseconds: 70)
          : const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      width: width,
      height: 9,
      decoration: BoxDecoration(
        color: active
            ? color.withValues(alpha: peak ? 1 : 0.82)
            : trackColor,
        borderRadius: BorderRadius.circular(2),
        boxShadow: peak
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.16),
                  blurRadius: 5,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

class _CallSettingsDialog extends StatefulWidget {
  const _CallSettingsDialog({required this.bridge});

  final PjsipNativeBridge bridge;

  @override
  State<_CallSettingsDialog> createState() => _CallSettingsDialogState();
}

class _CallSettingsDialogState extends State<_CallSettingsDialog> {
  late bool autoHoldOnIncoming;
  StreamSubscription<PjsipAudioDeviceState>? audioDeviceSubscription;
  PjsipAudioDeviceState? audioDevice;
  bool loading = true;
  bool saving = false;
  String? message;

  @override
  void initState() {
    super.initState();
    autoHoldOnIncoming = widget.bridge.autoHoldOnIncoming;
    audioDevice = widget.bridge.currentAudioDevice;
    audioDeviceSubscription = widget.bridge.audioDeviceStream.listen((event) {
      if (mounted) setState(() => audioDevice = event);
    });
    unawaited(_loadSetting());
  }

  @override
  void dispose() {
    audioDeviceSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadSetting() async {
    await widget.bridge.settingsReady;
    if (!mounted) return;
    setState(() {
      autoHoldOnIncoming = widget.bridge.autoHoldOnIncoming;
      loading = false;
    });
  }

  Future<void> _changeAutoHold(bool enabled) async {
    setState(() {
      saving = true;
      message = null;
    });
    try {
      final result = await widget.bridge.setAutoHoldOnIncoming(enabled);
      if (!mounted) return;
      setState(() {
        if (result.success) autoHoldOnIncoming = enabled;
        message = result.message;
      });
    } on PjsipBridgeException catch (error) {
      if (mounted) setState(() => message = error.message);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune, size: 21),
          SizedBox(width: 9),
          Text('通话设定'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: const Color(0xffedf4f1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xffc8d9d3)),
              ),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                value: autoHoldOnIncoming,
                onChanged: saving || loading
                    ? null
                    : (value) => unawaited(_changeAutoHold(value)),
                secondary: const Icon(Icons.call_received),
                title: const Text(
                  '接听新来电时自动保持当前通话',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  autoHoldOnIncoming
                      ? '已开启。接听新来电前，会向其他已接通线路发送 SIP Hold。'
                      : '已关闭。不会自动发送 SIP Hold，多路音频可能同时接入，请按需手动保持线路。',
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildAudioDeviceCard(),
            if (saving || loading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (message != null) ...[
              const SizedBox(height: 12),
              Text(message!, style: const TextStyle(color: Color(0xff52635f))),
            ],
            const SizedBox(height: 12),
            const Text(
              '当前不会在活动通话结束后自动恢复被保持的线路。',
              style: TextStyle(fontSize: 12, color: Color(0xff687773)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving || loading
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Widget _buildAudioDeviceCard() {
    final device = audioDevice;
    final switching = device?.status == PjsipAudioDeviceStatus.switching;
    final failed = device?.status == PjsipAudioDeviceStatus.error;
    final accent = failed
        ? const Color(0xffb54708)
        : switching
            ? const Color(0xff315c70)
            : const Color(0xff007a5e);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.headphones, size: 19, color: accent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '音频设备',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const Text(
                  '跟随系统',
                  style: TextStyle(fontSize: 12, color: Color(0xff52635f)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _AudioDeviceRow(
              icon: Icons.mic,
              label: '输入设备',
              value: device?.captureDevice ?? '等待音频引擎初始化',
            ),
            const SizedBox(height: 9),
            _AudioDeviceRow(
              icon: Icons.volume_up,
              label: '输出设备',
              value: device?.playbackDevice ?? '等待音频引擎初始化',
            ),
            if (device != null && device.message.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                device.message,
                style: TextStyle(fontSize: 12, color: accent),
              ),
            ],
            if (switching) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
            ],
          ],
        ),
      ),
    );
  }
}

class _AudioDeviceRow extends StatelessWidget {
  const _AudioDeviceRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: const Color(0xff52635f)),
        const SizedBox(width: 8),
        SizedBox(
          width: 68,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _BlindTransferDialog extends StatefulWidget {
  const _BlindTransferDialog({required this.remoteUri});

  final String remoteUri;

  @override
  State<_BlindTransferDialog> createState() =>
      _BlindTransferDialogState();
}

class _BlindTransferDialogState extends State<_BlindTransferDialog> {
  final destinationController = TextEditingController();
  String? errorText;

  void _submit() {
    final destination = destinationController.text.trim();
    if (destination.isEmpty) {
      setState(() => errorText = '请输入转接号码');
      return;
    }
    Navigator.of(context).pop(destination);
  }

  @override
  void dispose() {
    destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.phone_forwarded, size: 21),
          SizedBox(width: 9),
          Text('盲转通话'),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.remoteUri,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xff52635f)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: destinationController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: '转接号码或 SIP URI',
                hintText: '例如 6522',
                errorText: errorText,
                prefixIcon: const Icon(Icons.dialpad),
              ),
              onChanged: (_) {
                if (errorText != null) setState(() => errorText = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            const Text(
              '提交后将直接发送转接请求，不会先呼叫目标号码。',
              style: TextStyle(fontSize: 12, color: Color(0xff6b7572)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.phone_forwarded),
          label: const Text('确认转接'),
        ),
      ],
    );
  }
}

class _DtmfPad extends StatefulWidget {
  const _DtmfPad({required this.remoteUri, required this.onDigit});

  final String remoteUri;
  final Future<void> Function(String digit) onDigit;

  @override
  State<_DtmfPad> createState() => _DtmfPadState();
}

class _DtmfPadState extends State<_DtmfPad> {
  String enteredDigits = '';

  @override
  Widget build(BuildContext context) {
    const digits = <String>['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return AlertDialog(
      title: const Text('DTMF 拨号键盘'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.remoteUri, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            Container(
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xffedf4f1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                enteredDigits.isEmpty ? '按键将直接发送' : enteredDigits,
                style: const TextStyle(fontSize: 20, letterSpacing: 4),
              ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.55,
              physics: const NeverScrollableScrollPhysics(),
              children: digits.map((digit) {
                return FilledButton.tonal(
                  onPressed: () {
                    setState(() => enteredDigits += digit);
                    unawaited(widget.onDigit(digit));
                  },
                  child: Text(digit, style: const TextStyle(fontSize: 22)),
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
