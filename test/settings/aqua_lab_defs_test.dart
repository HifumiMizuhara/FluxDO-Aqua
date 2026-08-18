import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/settings/definitions/aqua_lab_defs.dart';
import 'package:fluxdo/settings/definitions/preferences_defs.dart';
import 'package:fluxdo/settings/definitions/reading_defs.dart';
import 'package:fluxdo/settings/settings_model.dart';

List<String> _visibleIds(List<SettingsGroup> groups) {
  return [
    for (final item in groups.expand((group) => group.items))
      if (item is PlatformConditionalModel) item.inner.id else item.id,
  ];
}

void main() {
  testWidgets('AquaラボにSVG実験機能を集約し、元ページから除去する', (tester) async {
    late List<SettingsGroup> aquaGroups;
    late List<SettingsGroup> preferenceGroups;
    late List<SettingsGroup> readingGroups;

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Builder(
            builder: (context) {
              aquaGroups = buildAquaLabGroups(context);
              preferenceGroups = buildPreferencesGroups(context);
              readingGroups = buildReadingGroups(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(_visibleIds(aquaGroups), contains('experimentalNativeSvgFix'));
    expect(
      _visibleIds(aquaGroups),
      contains('experimentalPrivateMessageCategories'),
    );
    expect(
      _visibleIds(preferenceGroups),
      isNot(contains('experimentalNativeSvgFix')),
    );
    expect(_visibleIds(readingGroups), isNot(contains('signatureSvgWebView')));
  });

  testWidgets('Aquaラボに「より良いCF突破」トグルがある', (tester) async {
    late List<SettingsGroup> aquaGroups;

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('ja'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Builder(
            builder: (context) {
              aquaGroups = buildAquaLabGroups(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(_visibleIds(aquaGroups), contains('betterCfBypass'));
  });
}
