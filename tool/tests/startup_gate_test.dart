import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medisense/startup_gate.dart';

void main() {
  testWidgets('draws Flutter startup UI before initialization completes', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      StartupGate(
        initialize: () => pending.future,
        child: const MaterialApp(home: Text('Ready')),
      ),
    );

    expect(find.text('MediSense'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Ready'), findsNothing);

    pending.complete();
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('shows a recoverable message when initialization fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupGate(
        initialize: () async => throw StateError('temporary failure'),
        child: const MaterialApp(home: Text('Ready')),
      ),
    );
    await tester.pump();

    expect(
      find.text('MediSense could not start. Close and reopen the app.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('replaces an indefinite spinner with a stalled message', (
    tester,
  ) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      StartupGate(
        initialize: () => pending.future,
        slowAfter: const Duration(seconds: 1),
        stalledAfter: const Duration(seconds: 2),
        child: const MaterialApp(home: Text('Ready')),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.text('Startup did not finish. Close and reopen MediSense.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    pending.complete();
    await tester.pump();
    expect(find.text('Ready'), findsOneWidget);
  });
}
