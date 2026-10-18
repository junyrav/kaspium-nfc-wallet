import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/kaspa/rpc/void_service.dart';

class SessionSigner implements SignerBase, SigningSession {
  final events = <String>[];
  bool reject = false;
  bool failSign = false;
  @override
  Future<void> beginSigning() async {
    events.add('begin');
    if (reject) throw StateError('Card/biometrics rejected');
  }
  @override
  void endSigning() => events.add('end');
  @override
  Future<bool> canSignForAddress(Address address) async => true;
  @override
  Future<Uint8List> sign(Uint8List data, Address address) async {
    events.add('sign');
    if (failSign) throw StateError('Signing failed');
    return Uint8List(64);
  }
}

class RecordingRpc extends VoidRpcService {
  int submissions = 0;
  @override
  Future<String> submitTransaction(RawTransaction tx, {bool allowOrphan = false}) async {
    submissions++;
    return 'test-txid';
  }
}

RawTransaction transaction() {
  final address = Address.publicKey(prefix: AddressPrefix.kaspa, publicKey: Uint8List(32));
  final script = ScriptPublicKey(version: 0, scriptPublicKey: Uint8List(0));
  return RawTransaction(
    version: 0,
    inputs: List.generate(2, (i) => RawInput(
      address: address,
      previousOutpoint: Outpoint(transactionId: '00' * 32, index: i),
      signatureScript: Uint8List(66),
      sequence: BigInt.zero,
      sigOpCount: 1,
      utxoEntry: UtxoEntry(amount: BigInt.from(1000), scriptPublicKey: script,
        blockDaaScore: BigInt.zero, isCoinbase: false),
    )),
    outputs: [RawOutput(value: BigInt.from(1900), scriptPublicKey: script)],
    lockTime: BigInt.zero, subnetworkId: kSubnetworkIdNative, gas: BigInt.zero,
  );
}

void main() {
  test('one authorization covers every transaction input and ends before submission', () async {
    final signer = SessionSigner();
    final rpc = RecordingRpc();
    final service = WalletService(signer: signer, rpc: rpc);
    expect(await service.sendTransaction(transaction()), 'test-txid');
    expect(signer.events, ['begin', 'sign', 'sign', 'end']);
    expect(rpc.submissions, 1);
  });
  test('denied authorization cannot sign or broadcast and always clears session', () async {
    final signer = SessionSigner()..reject = true;
    final rpc = RecordingRpc();
    final service = WalletService(signer: signer, rpc: rpc);
    await expectLater(service.sendTransaction(transaction()), throwsStateError);
    expect(signer.events, ['begin', 'end']);
    expect(rpc.submissions, 0);
  });
  test('signing failure clears session and does not broadcast', () async {
    final signer = SessionSigner()..failSign = true;
    final rpc = RecordingRpc();
    await expectLater(WalletService(signer: signer, rpc: rpc).sendTransaction(transaction()), throwsStateError);
    expect(signer.events, ['begin', 'sign', 'end']);
    expect(rpc.submissions, 0);
  });
  test('message signing uses the same NFC authorization boundary', () async {
    final signer = SessionSigner()..reject = true;
    final service = WalletService(signer: signer, rpc: RecordingRpc());
    final address = Address.publicKey(prefix: AddressPrefix.kaspa, publicKey: Uint8List(32));
    await expectLater(service.signPersonalMessage('test', address: address), throwsStateError);
    expect(signer.events, ['begin', 'end']);
  });
}
