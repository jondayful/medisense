import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:medisense/models/accessibility_mode.dart';
import 'package:medisense/providers/app_state_provider.dart';
import 'package:medisense/providers/auth_provider.dart';
import 'package:medisense/providers/tts_provider.dart';
import 'package:medisense/providers/voice_navigation_provider.dart';
import 'package:medisense/screens/settings_screen.dart';
import 'package:medisense/theme/app_theme.dart';
import 'package:medisense/widgets/medi_bottom_nav.dart';
import 'package:medisense/widgets/vision_voice_fab.dart';

class _SettingsAppState extends AppStateProvider {
  _SettingsAppState(this.mode, {this.dark = false});

  final AccessibilityMode mode;
  final bool dark;

  @override
  AccessibilityMode get accessibilityMode => mode;

  @override
  bool get darkMode => dark;
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required AccessibilityMode mode,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(375, 812));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppStateProvider>.value(
            value: _SettingsAppState(mode, dark: dark),
          ),
          ChangeNotifierProvider.value(value: AuthProvider()),
          ChangeNotifierProvider.value(value: TtsProvider()),
          ChangeNotifierProvider(create: (_) => VoiceNavigationProvider()),
        ],
        child: const SettingsScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('standard settings fit a small phone without overflow', (
    tester,
  ) async {
    await _pumpSettings(tester, mode: AccessibilityMode.none);

    expect(find.text('Account'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Voice Settings'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Voice Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);

    for (final element in find.byTooltip('Test audio').evaluate()) {
      final size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('large-text dark settings use the same grouped layout', (
    tester,
  ) async {
    await _pumpSettings(tester, mode: AccessibilityMode.visionLoss, dark: true);

    expect(find.text('Display Mode'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Volume / Loudness'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Volume / Loudness'), findsOneWidget);
    expect(find.text('Quiet'), findsOneWidget);
    expect(find.text('Loud'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice navigation toggle keeps the bottom capsule anchored', (
    tester,
  ) async {
    await _pumpSettings(tester, mode: AccessibilityMode.none);
    final original = tester.getRect(find.byType(MediBottomNav));
    await tester.scrollUntilVisible(
      find.text('Voice Navigation'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Voice Navigation'));
    await tester.pumpAndSettle();
    expect(find.byType(VisionVoiceFab), findsOneWidget);
    expect(tester.getRect(find.byType(MediBottomNav)), original);
    await tester.tap(find.text('Voice Navigation'));
    await tester.pumpAndSettle();
    expect(find.byType(VisionVoiceFab), findsNothing);
    expect(tester.getRect(find.byType(MediBottomNav)), original);
  });

  testWidgets('cloud OCR needs an explicit choice before enabling', (
    tester,
  ) async {
    await _pumpSettings(tester, mode: AccessibilityMode.none);
    final appState = Provider.of<AppStateProvider>(
      tester.element(find.byType(SettingsScreen)),
      listen: false,
    );
    await tester.scrollUntilVisible(
      find.text('Cloud scan assistance'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Cloud scan assistance'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cloud scan assistance'));
    await tester.pumpAndSettle();
    expect(find.text('Send unclear scans to Google?'), findsOneWidget);
    expect(appState.cloudOcrConsent, isFalse);

    await tester.tap(find.text('Keep scans on device'));
    await tester.pumpAndSettle();
    expect(appState.cloudOcrConsent, isFalse);

    await tester.tap(find.text('Cloud scan assistance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I agree'));
    await tester.pumpAndSettle();
    expect(appState.cloudOcrConsent, isTrue);
  });
}
