import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../kaspa/kaspa.dart';
import 'wallet_signer.dart';

final _walletSignerProvider = Provider.autoDispose((ref) {
  final addressNotifier = ref.watch(addressNotifierProvider);
  final walletAuth = ref.watch(walletAuthProvider.notifier);

  final signer = WalletSigner(addressNotifier, walletAuth);
  ref.onDispose(signer.endSigning);
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
