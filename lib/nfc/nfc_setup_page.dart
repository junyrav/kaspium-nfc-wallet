import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../intro/intro_providers.dart';
import '../kaspa/kaspa.dart';
import 'nfc_wallet.dart';

String _newSeed(int _) => mnemonicToSeedHex(generateMnemonic(strength: 256));

class NfcSetupPage extends ConsumerStatefulWidget {
  final bool recovery;
  const NfcSetupPage({super.key, this.recovery = false});

  @override
  ConsumerState<NfcSetupPage> createState() => _NfcSetupPageState();
}

class _NfcSetupPageState extends ConsumerState<NfcSetupPage> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController(text: 'Kaspa NFC Wallet');
  bool _busy = false;
  bool _ready = false;
  bool _completed = false;
  int _count = 0;
  int _recoveryCount = 0;
  String? _kpub;
  String _message = '';

  @override
  void initState() {
    super.initState();
    NfcWallet.initialize();
    unawaited(NfcWallet.clear());
  }

  @override
  void dispose() {
    _password.dispose(); _confirm.dispose(); _name.dispose();
    unawaited(NfcWallet.cancel().then((_) => NfcWallet.clear()));
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _message = ''; });
    try { await action(); }
    on PlatformException catch (e) {
      if (mounted) setState(() => _message = e.message ?? 'NFC 작업 실패');
    } catch (_) {
      if (mounted) setState(() => _message = '작업에 실패했습니다. 카드와 복구 비밀번호를 확인하세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _begin() async {
    if (_password.text.length < 12 ||
        (!widget.recovery && _password.text != _confirm.text)) {
      setState(() => _message = '12자 이상의 복구 비밀번호와 확인 입력을 확인하세요.');
      return;
    }
    await _run(() async {
      Uint8List? seed;
      try {
        if (widget.recovery) {
          final recovered = await NfcWallet.recover(_password.text);
          seed = recovered.$1;
          final kpub = HdWallet.hdPublicKeyFromSeed(seed, networkType: kaspaMainnet);
          if (!listEquals(NfcWallet.fingerprint(kpub), recovered.$2)) {
            throw StateError('Recovery wallet mismatch');
          }
          _kpub = kpub;
        } else {
          seed = hexToBytes(await compute(_newSeed, 0));
          _kpub = HdWallet.hdPublicKeyFromSeed(seed, networkType: kaspaMainnet);
        }
        await NfcWallet.begin(seed, _kpub!, _password.text, rebind: widget.recovery);
        if (mounted) setState(() {
          _ready = true;
          _message = widget.recovery
              ? '복구한 카드 2장을 차례로 다시 태그해 이 휴대폰에 등록하세요. 기존 복구 조각은 유지됩니다.'
              : '빈 카드 3장을 차례로 태그하세요. 기존 지갑 카드에는 덮어쓰지 않습니다.';
        });
      } finally { seed?.fillRange(0, seed.length, 0); }
    });
  }

  Future<void> _readRecovery() => _run(() async {
    final count = await NfcWallet.readRecovery();
    if (mounted) setState(() { _recoveryCount = count; _message = '복구 카드 확인 $count/2'; });
  });

  Future<void> _write() => _run(() async {
    final count = await NfcWallet.write(_count + 1);
    if (mounted) setState(() {
      _count = count;
      _completed = count >= (widget.recovery ? 2 : 3);
      _message = '카드 저장 및 읽기 검증 완료: $count/${widget.recovery ? 2 : 3}';
    });
  });

  void _finish() {
    final data = ref.read(introDataProvider.notifier);
    data.clear();
    data.setKpub(_kpub!);
    data.nfcWallet = true;
    data.setName(_name.text.trim().isEmpty ? 'Kaspa NFC Wallet' : _name.text.trim());
    _password.clear(); _confirm.clear();
    data.complete();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.recovery ? 'NFC 지갑 복구' : 'NFC 지갑 생성')),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const Icon(Icons.contactless, size: 64),
          const SizedBox(height: 20),
          Text(widget.recovery
              ? '이 앱에서 등록한 카드 3장 중 2장과 복구 비밀번호가 필요합니다. 이전 단일 개인키 앱의 카드는 호환되지 않습니다.'
              : '카드 3장에 암호화된 지갑과 복구 조각을 저장합니다. 송금은 카드 1장 + 강한 생체인증, 복구는 카드 2장 + 복구 비밀번호로 진행합니다.'),
          const SizedBox(height: 16),
          const Text('MIFARE Classic 지원 Android용입니다. Tangem 카드는 지원하지 않습니다. 복구 비밀번호를 잊으면 카드만으로 복구할 수 없습니다.'),
          const SizedBox(height: 16),
          TextField(controller: _name, enabled: !_busy && !_ready, decoration: const InputDecoration(labelText: '지갑 이름')),
          TextField(controller: _password, enabled: !_busy && !_ready, obscureText: true,
              autocorrect: false, enableSuggestions: false,
              decoration: const InputDecoration(labelText: '복구 비밀번호 (12자 이상)')),
          if (!widget.recovery)
            TextField(controller: _confirm, enabled: !_busy && !_ready, obscureText: true,
                autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: '복구 비밀번호 확인')),
          const SizedBox(height: 24),
          if (!_ready && widget.recovery && _recoveryCount < 2)
            FilledButton(onPressed: _busy ? null : _readRecovery, child: Text('복구 카드 읽기 ($_recoveryCount/2)')),
          if (!_ready && (!widget.recovery || _recoveryCount >= 2))
            FilledButton(onPressed: _busy ? null : _begin, child: Text(widget.recovery ? '복구 및 생체인증' : '새 지갑 생성 및 생체인증')),
          if (_ready && !_completed)
            FilledButton(onPressed: _busy ? null : _write, child: Text('카드 ${_count + 1} 태그하여 저장')),
          if (_completed) FilledButton(onPressed: _busy ? null : _finish, child: const Text('등록 완료 · 지갑 열기')),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            TextButton(onPressed: NfcWallet.cancel, child: const Text('작업 취소')),
          ],
          const SizedBox(height: 16),
          ValueListenableBuilder<String>(valueListenable: NfcWallet.progress,
            builder: (_, value, child) => Text(value)),
          const SizedBox(height: 8),
          Text(_message),
          if (widget.recovery && _completed)
            const Text('지금 등록한 두 카드로 송금할 수 있습니다. 나머지 카드는 복구에 계속 사용할 수 있으며 송금에는 이 휴대폰 등록이 필요합니다.'),
        ]),
      ),
    );
  }
}
