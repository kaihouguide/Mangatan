import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/core/navigation/app_navigator.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/modules/more/settings/sync/widgets/sync_error_details_dialog.dart';
import 'package:mangayomi/router/router.dart';

void main() {
  group('syncErrorDetails', () {
    test('includes the type, the message and the stack', () {
      final details = syncErrorDetails(
        StateError('Local data changed after the preview'),
        StackTrace.fromString('#0 first\n#1 second'),
      );

      expect(details, startsWith('Error: StateError'));
      expect(details, contains('Local data changed after the preview'));
      expect(details, contains('#0 first'));
      expect(details, contains('#1 second'));
    });

    test('removes credentials, URL paths and home folders', () {
      final details = syncErrorDetails(
        Exception(
          'GET http://sync.example.test:8282/api/sync/content?token=abc '
          'failed in /Users/someone/Library',
        ),
        null,
      );

      expect(details, contains('sync.example.test:8282'));
      expect(details, isNot(contains('/api/sync/content')));
      expect(details, isNot(contains('abc')));
      expect(details, isNot(contains('someone')));
    });

    test('caps a long stack', () {
      final stack = List.generate(30, (i) => '#$i frame').join('\n');
      final details = syncErrorDetails(
        Exception('x'),
        StackTrace.fromString(stack),
        maxStackLines: 5,
      );

      expect(details, contains('#4 frame'));
      expect(details, isNot(contains('#5 frame')));
      expect(details, contains('25 more frame(s)'));
    });
  });

  testWidgets('the text box is read-only, selectable and copyable', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SyncErrorDetailsDialog(details: 'Error: X\nwhy')),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);
    expect(field.enableInteractiveSelection, isTrue);
    expect(field.controller?.text, 'Error: X\nwhy');

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'Error: X\nwhy');
    expect(find.text('Copied'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('tapping Details on the toast opens the dialog', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: BotToastInit(),
        navigatorObservers: [BotToastNavigatorObserver()],
        home: const Scaffold(body: SizedBox()),
      ),
    );

    botToast(
      'Sync failed safely. Try again.',
      second: 8,
      detailsLabel: 'Details',
      onDetails: () => AppNavigator.showAppDialog<void>(
        (_) => const SyncErrorDetailsDialog(details: 'Error: X\nreason'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sync failed safely. Try again.'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.text('Sync error details'), findsOneWidget);
    expect(find.text('Error: X\nreason'), findsOneWidget);
    // The toast dismissed itself when its action was used.
    expect(find.text('Sync failed safely. Try again.'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Sync error details'), findsNothing);
  });
}
