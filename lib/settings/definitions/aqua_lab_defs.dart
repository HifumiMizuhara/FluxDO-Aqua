import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import '../../providers/preferences_provider.dart';
import '../../services/preloaded_data_service.dart';
import '../settings_model.dart';

/// Aqua ラボの設定項目。
///
/// 保存処理は既存の [PreferencesNotifier] を利用するため、設定の移動に
/// よって既存ユーザーの値や互換性は変わらない。
List<SettingsGroup> buildAquaLabGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    SettingsGroup(
      title: l10n.aquaLab_svg,
      icon: Symbols.auto_awesome_rounded,
      items: [
        // サーバー側で署名機能が有効な場合だけ表示する既存条件を維持する。
        if (PreloadedDataService().signaturesEnabled)
          SwitchModel(
            id: 'signatureSvgWebView',
            title: l10n.reading_signatureSvgWebView,
            subtitle: l10n.reading_signatureSvgWebViewDesc,
            icon: Symbols.language_rounded,
            getValue: (ref) =>
                ref.watch(preferencesProvider).signatureSvgWebView,
            onChanged: (ref, value) => ref
                .read(preferencesProvider.notifier)
                .setSignatureSvgWebView(value),
          ),
        SwitchModel(
          id: 'experimentalNativeSvgFix',
          title: l10n.preferences_experimentalNativeSvgFix,
          subtitle: l10n.preferences_experimentalNativeSvgFixDesc,
          icon: Symbols.speed_rounded,
          getValue: (ref) =>
              ref.watch(preferencesProvider).experimentalNativeSvgFix,
          onChanged: (ref, value) => ref
              .read(preferencesProvider.notifier)
              .setExperimentalNativeSvgFix(value),
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.aquaLab_privateMessages,
      icon: Symbols.forum_rounded,
      items: [
        SwitchModel(
          id: 'experimentalPrivateMessageCategories',
          title: l10n.preferences_experimentalPrivateMessageCategories,
          subtitle: l10n.preferences_experimentalPrivateMessageCategoriesDesc,
          icon: Symbols.groups_rounded,
          getValue: (ref) => ref
              .watch(preferencesProvider)
              .experimentalPrivateMessageCategories,
          onChanged: (ref, value) => ref
              .read(preferencesProvider.notifier)
              .setExperimentalPrivateMessageCategories(value),
        ),
      ],
    ),
  ];
}
