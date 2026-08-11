import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../services/eruda_settings_service.dart';
import '../../../l10n/s.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// Eruda 设备内 DevTools 开关卡片（调试用）。
///
/// 开启后, 主站 WebView 页面右下角出现 ⚙ 悬浮按钮, 可打开
/// Console / Network / Elements / Sources 面板。默认关闭。
/// 见 [ErudaSettingsService]。
class ErudaCard extends StatelessWidget {
  const ErudaCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = ErudaSettingsService.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: service.notifier,
      builder: (context, enabled, _) {
        return SegmentedCardGroup(
          color: enabled
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : null,
          children: [
            SwitchListTile(
              title: Text(context.l10n.network_erudaConsole),
              subtitle: Text(
                enabled
                    ? context.l10n.network_erudaEnabled
                    : context.l10n.network_erudaDisabled,
              ),
              secondary: Icon(Symbols.terminal_rounded, fill: enabled ? 1 : 0,
                color: enabled ? theme.colorScheme.primary : null,
              ),
              value: enabled,
              onChanged: (value) => service.setEnabled(value),
            ),
            if (enabled)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Symbols.info_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.network_erudaRestartHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
