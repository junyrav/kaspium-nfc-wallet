import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_router.dart';
import '../nfc/nfc_setup_page.dart';
import 'package:flutter/foundation.dart';
import '../l10n/l10n.dart';
import '../util/ui_util.dart';
import '../widgets/action_buttons_wrapper.dart';
import '../widgets/buttons.dart';
import 'intro_providers.dart';

class IntroActionsWidget extends ConsumerWidget {
  const IntroActionsWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = l10nOf(context);

    void newWallet() {
      final notifier = ref.read(introStateProvider.notifier);
      try {
        notifier.newWallet();
      } catch (e) {
        UIUtil.showSnackbar(l10n.somethingWentWrong);
        appRouter.reload(context);
      }
    }

    void importWallet() {
      final notifier = ref.read(introStateProvider.notifier);
      notifier.importSelect();
    }

    return ActionButtonsWrapper(
      buttons: [
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
          PrimaryButton(title: 'NFC 지갑 생성', onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const NfcSetupPage()))),
          PrimaryOutlineButton(title: 'NFC 카드로 복구', onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const NfcSetupPage(recovery: true)))),
        ],
        PrimaryButton(title: '소프트웨어 지갑 생성', onPressed: newWallet),
        PrimaryOutlineButton(title: '시드·공개키로 가져오기', onPressed: importWallet),
      ],
    );
  }
}
