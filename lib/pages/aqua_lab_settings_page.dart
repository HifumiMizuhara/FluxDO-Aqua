import 'package:flutter/material.dart';

import '../l10n/s.dart';
import '../settings/definitions/aqua_lab_defs.dart';
import '../widgets/settings/settings_group_page.dart';

/// Aqua ラボ設定ページ。
///
/// アプリ固有の実験的な描画機能を、通常の機能設定から分離して表示する。
class AquaLabSettingsPage extends StatelessWidget {
  final String? highlightId;

  const AquaLabSettingsPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.settings_aquaLab,
      groupsBuilder: buildAquaLabGroups,
      highlightId: highlightId,
    );
  }
}
