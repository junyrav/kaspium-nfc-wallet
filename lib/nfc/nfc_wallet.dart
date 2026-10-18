import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NfcWallet {
  static const channel = MethodChannel('kaspa_nfc/v1');
  static final progress = ValueNotifier<String>('');
  static bool _initialized = false;

  static void initialize() {
    if (_initialized) return;
    _initialized = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') progress.value = call.arguments as String;
    });
  }

  static Uint8List fingerprint(String kpub) =>
      Uint8List.fromList(sha256.convert(utf8.encode(kpub)).bytes);

  static Future<void> begin(Uint8List seed, String kpub, String password,
      {bool rebind = false}) async {
    initialize();
    await channel.invokeMethod<void>('begin', {
      'seed': seed,
      'wallet': fingerprint(kpub),
      'password': password,
      'rebind': rebind,
    });
  }

  static Future<int> write(int slot) async =>
      (await channel.invokeMethod<int>('write', {'slot': slot}))!;

  static Future<Uint8List> unlock(String kpub) async {
    initialize();
    progress.value = 'NFC 카드 1장을 태그한 뒤 생체인증을 완료하세요';
    final seed = await channel.invokeMethod<Uint8List>(
        'unlock', {'wallet': fingerprint(kpub)});
    if (seed == null || seed.length != 64) {
      throw StateError('Invalid NFC seed');
    }
    return seed;
  }

  static Future<int> readRecovery() async {
    initialize();
    return (await channel.invokeMethod<int>('readRecovery'))!;
  }

  static Future<(Uint8List, Uint8List)> recover(String password) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
        'recover', {'password': password});
    return (result!['seed'] as Uint8List, result['wallet'] as Uint8List);
  }

  static Future<void> cancel() => channel.invokeMethod<void>('cancel');
  static Future<void> clear() => channel.invokeMethod<void>('clear');
}
