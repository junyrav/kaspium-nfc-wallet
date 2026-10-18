import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../app_providers.dart';
import '../app_router.dart';
import '../intro/intro_providers.dart';
import '../kaspa/kaspa.dart';
import '../kaspa/rpc/void_service.dart';
import '../l10n/l10n.dart';
import '../wallet/wallet_types.dart';
import '../wallet_address/address_discovery.dart';
import '../widgets/content_wrapper.dart';
import 'confirm_legacy_dialog.dart';
import 'setup_failed_page.dart';

class SetupWalletScreen extends HookConsumerWidget {
  const SetupWalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final setupFailed = useState(false);
    final setupError = useRef<Object?>(null);

    final message = useState(l10n.walletSetupMessage);
    final details = useState('');

    Future<bool> checkLegacyWallet(String seed) async {
      try {
        final api = ref.read(kaspaApiServiceProvider);
        final prefix = ref.read(addressPrefixProvider);

        final wallet = HdWallet.forSeedHex(seed, type: .legacy);
        final addresses = <String>[];

        for (int ti = 0; ti < 2; ti++) {
          for (int i = 0; i < 10; i++) {
            final pubKey = wallet.derivePublicKey(typeIndex: ti, index: i);
            final address = Address.publicKey(
              prefix: prefix,
              publicKey: pubKey,
            );
            addresses.add(address.encoded);
          }
        }

        final active = await api.checkActive(addresses: addresses);
        return active.any((a) => a.active);
      } catch (_) {}
      return false;
    }

    Future<bool> confirmLegacyWallet(String seed) async {
      final isLegacy = await checkLegacyWallet(seed);

      if (!isLegacy) return false;
      if (!context.mounted) return false;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => const ConfirmLegacyWalletDialog(),
      );

      return confirmed == true;
    }

    Future<void> setupWallet() async {
      try {
        setupFailed.value = false;
        final isNfc = ref.read(introDataProvider.notifier).nfcWallet;
        final introData = ref.read(introDataProvider);
        ref.read(introDataProvider.notifier).clear();

        final seed = await introData.seed;

        final WalletData walletData;
        if (introData.kpub case final kpub?) {
          final walletKind = WalletKind.localHdSchnorr(viewOnly: !isNfc);
          walletData = .kpub(
            name: introData.name ?? l10n.defaultWalletName,
            kind: walletKind,
            kpub: kpub,
          );
        } else {
          if (seed == null) {
            throw Exception('Missing seed');
          }
          WalletKind walletKind;
          if (introData.isLegacyWallet || await confirmLegacyWallet(seed)) {
            final wallet = HdWallet.forSeedHex(seed, type: .legacy);
            final pubKey = wallet.derivePublicKey(typeIndex: 0, index: 0);
            walletKind = .localHdLegacy(mainPubKey: pubKey.hex);
          } else {
            walletKind = .localHdSchnorr();
          }

          walletData = .seed(
            name: introData.name ?? l10n.defaultWalletName,
            kind: walletKind,
            seed: seed,
            usesBip39Passphrase: introData.bip39Passphrase.isNotEmpty,
            mnemonic: introData.mnemonic,
            password: introData.password,
          );
        }

        // setup wallet
        final network = ref.read(networkProvider);
        final networkId = ref.read(networkIdProvider);
        final notifier = ref.read(walletBundleProvider.notifier);
        final wallet = await notifier.setupWallet(walletData, nfc: isNfc);
        await notifier.selectWallet(wallet, networkId);

        final auth = ref.read(walletAuthNotifierProvider);
        if (auth == null) throw Exception('No active wallet');
        await auth.syncState();
        if (auth.needsLegacyPasswordAuth) {
          await auth.unlock(password: introData.password);
        } else {
          await auth.unlock();
        }

        // address discovery
        final nodeConfig = ref.read(kaspaNodeConfigProvider);
        RpcService rpc;
        try {
          rpc = GrpcService.url(
            nodeConfig.url,
            tls: nodeConfig.isSecure,
            timeout: const Duration(seconds: 10),
          );
          await rpc.connect();
        } catch (e) {
          ref.read(loggerProvider).w('Scanning without a node', error: e);
          rpc = VoidRpcService();
        }

        WalletDiscoveryResult discovery;
        try {
          final api = ref.read(kaspaApiServiceProvider);
          final addressGenerator = auth.addressGenerator(network);

          final addressDiscovery = AddressDiscovery(
            rpc: rpc,
            api: api,
            addressGenerator: addressGenerator,
            addressNameCallback: (type, index) => switch (type) {
              .receive => l10n.receiveIndexParam('$index'),
              .change => l10n.changeIndexParam('$index'),
            },
          );

          if (network == .mainnet && !introData.generated) {
            message.value = l10n.walletSetupAddressDiscovery;
            discovery = await addressDiscovery.addressDiscovery(
              startReceiveIndex: 0,
              startChangeIndex: 0,
              onProgress: (type, index) {
                message.value = switch (type) {
                  .receive => l10n.scanningReceiveAddresses,
                  .change => l10n.scanningChangeAddresses,
                };
                details.value = l10n.addressesChecked(index);
                return true;
              },
            );

            if (discovery.receive.addresses.isEmpty) {
              discovery = (
                receive: DiscoveryResult(
                  addresses: {0: addressDiscovery.mainAddress},
                  scanIndexes: discovery.receive.scanIndexes,
                ),
                change: discovery.change,
              );
            }
          } else {
            discovery = addressDiscovery.newWalletDiscoveryResult;
          }
        } finally {
          await rpc.disconnect();
        }

        final walletRepository = ref.read(walletRepositoryProvider);
        await walletRepository.openWalletBoxes(wallet, networkId: networkId);

        final addressBox = ref.read(addressBoxProvider(wallet));

        await addressBox.setAll({
          for (final address in discovery.addresses) address.key: address,
        });

        await walletRepository.closeWalletBoxes(wallet, networkId: networkId);

        message.value = l10n.fetchingTransactions;
        details.value = '';

        if (!context.mounted) return;
        appRouter.reload(context);
      } catch (e, st) {
        final log = ref.read(loggerProvider);
        log.e('Failed to create wallet', error: e, stackTrace: st);

        setupFailed.value = true;
        setupError.value = e;
      }
    }

    useEffect(() {
      Future.delayed(const Duration(milliseconds: 200), setupWallet);
      return null;
    }, const []);

    if (setupFailed.value) {
      return SetupFailedPage(
        error: setupError.value,
        onRestart: () => appRouter.reload(context),
      );
    }

    return ContentWrapper(
      child: Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: .spaceEvenly,
              children: [
                FractionallySizedBox(
                  widthFactor: 0.4,
                  child: FittedBox(
                    fit: .fitWidth,
                    child: Image.asset('assets/kaspa.png'),
                  ),
                ),
                Column(
                  children: [
                    Text(
                      message.value,
                      style: styles.textStyleSettingItemHeaderLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      details.value,
                      style: styles.textStyleSettingItemHeader60,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(
            width: .infinity,
            height: 16 + 2 * 55,
          ),
        ],
      ),
    );
  }
}
