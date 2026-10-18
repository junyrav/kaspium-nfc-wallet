import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../kaspa/kaspa.dart';
import 'wallet_signer.dart';

final _walletSignerProvider = Provider.autoDispose((ref) {
  final addressNotifier = ref.watch(addressNotifierProvider);
  final walletAuth = ref.watch(walletAuthProvider.notifier);

  void Function()? closeSession;
  final signer = WalletSigner(addressNotifier, walletAuth,
    onSessionStart: () { closeSession ??= ref.keepAlive().close; },
    onSessionEnd: () { closeSession?.call(); closeSession = null; },
  );
  ref.onDispose(signer.dispose);
  return signer;
});

final walletServiceProvider = Provider.autoDispose((ref) {
  final signer = ref.watch(_walletSignerProvider);
  final rpc = ref.watch(kaspaRpcProvider);

  return WalletService(
    signer: signer,
    rpc: rpc,
  );
});
