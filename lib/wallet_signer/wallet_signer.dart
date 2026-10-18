import '../kaspa/kaspa.dart';
import '../nfc/nfc_wallet.dart';
import '../wallet_address/wallet_address_notifier.dart';
import '../wallet_auth/wallet_auth_notifier.dart';

class WalletSigner implements SignerBase, SigningSession {
  Uint8List? _nfcSeed;
  bool _disposed = false;
  final void Function()? onSessionStart;
  final void Function()? onSessionEnd;
  final WalletAddressNotifier _wallet;
  final WalletAuthNotifier _walletAuth;

  WalletSigner(this._wallet, this._walletAuth, {this.onSessionStart, this.onSessionEnd});

  void dispose() { _disposed = true; endSigning(); }

  @override
  Future<void> beginSigning() async {
    if (!_walletAuth.state.wallet.isNfc) return;
    if (_disposed) throw StateError('Wallet signer is disposed');
    if (_nfcSeed != null) throw StateError('Signing already in progress');
    onSessionStart?.call();
    final kpub = _walletAuth.state.wallet.mainnetPublicKey;
    final seed = await NfcWallet.unlock(kpub);
    try {
      if (_disposed) throw StateError('Wallet changed during NFC authorization');
      if (HdWallet.hdPublicKeyFromSeed(seed, networkType: kaspaMainnet) != kpub) {
        throw StateError('NFC card does not match wallet');
      }
      _nfcSeed = Uint8List.fromList(seed);
    } finally { seed.fillRange(0, seed.length, 0); }
  }

  @override
  void endSigning() {
    final seed = _nfcSeed;
    _nfcSeed = null;
    seed?.fillRange(0, seed.length, 0);
    if (seed != null) NfcWallet.progress.value = '서명 완료';
    onSessionEnd?.call();
  }

  @override
  Future<bool> canSignForAddress(Address address) async {
    return _wallet.containsAddress(address.toString());
  }

  @override
  Future<Uint8List> sign(Uint8List data, Address address) async {
    int typeIndex = 0;
    var index = _wallet.indexOfReceiveAddress(address.encoded);
    if (index == null) {
      index = _wallet.indexOfChangeAddress(address.encoded);
      typeIndex = 1;
      if (index == null) {
        throw Exception('Address not found');
      }
    }
    if (_walletAuth.state.wallet.isNfc) {
      final seed = _nfcSeed;
      if (_disposed || seed == null) throw StateError('NFC authorization is required');
      final hd = HdWallet.forSeedHex(seed.hex, type: _walletAuth.state.wallet.kind.type);
      final key = hd.deriveKeyPair(typeIndex: typeIndex, index: index).privateKey;
      try {
        return await WalletAuthNotifier.computeSignDataSchnorr(data, key);
      } finally { key.fillRange(0, key.length, 0); }
    }
    final signature = await _walletAuth.sign(
      data,
      typeIndex: typeIndex,
      index: index,
    );
    return signature;
  }
}
