import '../rpc.dart';
import '../transaction.dart';
import '../types.dart';
import '../utils.dart';
import 'send_tx.dart';
import 'signer_base.dart';

typedef SignatureDetails = ({String signature, String hash});

class WalletService {
  final SignerBase signer;
  final RpcService rpc;

  const WalletService({
    required this.signer,
    required this.rpc,
  });

  SendTx createSendTx({
    required Address toAddress,
    required Amount amount,
    required List<Utxo> spendableUtxos,
    List<Utxo>? selectedUtxos,
    required int feeRate,
    Amount? minFee,
    required Address changeAddress,
    Uint8List? payload,
    String? note,
  }) {
    final txBuilder = TxBuilder(
      utxos: spendableUtxos,
      changeAddress: changeAddress,
      payload: payload,
      feeRate: .from(feeRate),
      minFee: minFee?.raw ?? .zero,
    );

    final tx = txBuilder.createTx(
      selectedUtxos: selectedUtxos,
      address: toAddress,
      amount: amount.raw,
    );

    return SendTx(
      uri: KaspaUri(
        address: toAddress,
        amount: amount,
      ),
      tx: tx,
      utxos: txBuilder.selectedUtxos,
      userSelected: selectedUtxos?.isNotEmpty ?? false,
      amount: amount,
      change: .raw(txBuilder.change),
      changeAddress: txBuilder.changeAddress,
      note: note,
      mass: txBuilder.mass,
    );
  }

  SendTx createCompoundTx({
    required Address compoundAddress,
    required List<Utxo> utxos,
    required int feeRate,
    Amount? minFee,
  }) {
    final txBuilder = TxBuilder(
      utxos: utxos,
      changeAddress: compoundAddress,
      feeRate: .from(feeRate),
      minFee: minFee?.raw ?? .zero,
    );

    final tx = txBuilder.createCompoundTx();

    return SendTx(
      uri: KaspaUri(
        address: compoundAddress,
        amount: .raw(txBuilder.amount),
      ),
      tx: tx,
      utxos: txBuilder.selectedUtxos,
      amount: .raw(txBuilder.amount),
      change: .raw(txBuilder.change),
      changeAddress: txBuilder.changeAddress,
      mass: txBuilder.mass,
    );
  }

  void _validateFee(RawTransaction tx) {
    // hard cap on fee of 100 KAS
    if (tx.fee > kSompiPerKaspa * .from(100)) {
      throw Exception('Abnormal fee');
    }
  }

  Future<String> sendTransaction(RawTransaction tx, {bool rbf = false}) async {
    _validateFee(tx);

    final session = signer is SigningSession ? signer as SigningSession : null;
    try {
      await session?.beginSigning();
      await _signTransaction(tx);
    } finally {
      session?.endSigning();
    }

    if (rbf) {
      final result = await rpc.submitTransactionReplacement(tx);
      return result.$1;
    }

    final txId = await rpc.submitTransaction(tx);
    return txId;
  }

  Future<void> _signTransaction(RawTransaction tx) async {
    final hashType = SigHashType.sigHashAll;
    final reusedValues = SigHashReusedValues();

    // Sign all inputs
    for (int index = 0; index < tx.inputs.length; ++index) {
      final input = tx.inputs[index];

      final hash = getSchnorrSignatureHash(
        tx: tx,
        inputIndex: index,
        hashType: hashType,
        reusedValues: reusedValues,
      );

      final signature = await signer.sign(hash, input.address);

      final signatureScript =
          [signature.length + 1] + signature + [hashType.raw];
      input.signatureScript.setAll(0, signatureScript);
    }
  }

  Future<SignatureDetails> signPersonalMessage(
    String message, {
    required Address address,
  }) async {
    final canSign = await signer.canSignForAddress(address);
    if (!canSign) {
      throw Exception('Cannot sign for address $address');
    }

    final hash = hashPersonalMessage(message);
    final session = signer is SigningSession ? signer as SigningSession : null;
    try {
      await session?.beginSigning();
      final signature = await signer.sign(hash, address);
      return (signature: signature.hex, hash: hash.hex);
    } finally {
      session?.endSigning();
    }
  }
}
