import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/settings.dart';
import 'package:mangayomi/modules/more/settings/browse/providers/browse_state_provider.dart';
import 'package:mangayomi/modules/more/settings/browse/source_repositories.dart';

void main() {
  Future<void> openAddDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionsRepoStateProvider(ItemType.anime)
              .overrideWith(_ExistingRepoState.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SourceRepositories(itemType: ItemType.anime),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
  }

  TextButton addButton(WidgetTester tester) => tester.widget<TextButton>(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, 'Add'),
    ),
  );

  testWidgets('a pasted protobuf index enables Add without a field error', (
    tester,
  ) async {
    await openAddDialog(tester);
    expect(addButton(tester).onPressed, isNull);

    // Pasted links often carry a trailing newline.
    await tester.enterText(
      find.byType(TextFormField),
      'https://example.test/repo/index.min.pb\n',
    );
    await tester.pump();

    expect(addButton(tester).onPressed, isNotNull);
    expect(
      tester.state<FormFieldState<String>>(find.byType(TextFormField)).hasError,
      isFalse,
    );
  });

  testWidgets('the field and Add agree on rejected links', (tester) async {
    await openAddDialog(tester);

    for (final link in [
      'ftp://example.test/index.json',
      'https://example.test/existing/index.min.json/',
    ]) {
      await tester.enterText(find.byType(TextFormField), link);
      await tester.pump();
      expect(addButton(tester).onPressed, isNull, reason: link);
    }
    expect(find.text('Repository already exists!'), findsOneWidget);
  });
}

class _ExistingRepoState extends ExtensionsRepoState {
  @override
  List<Repo> build(ItemType itemType) => [
    Repo(
      name: 'Existing',
      jsonUrl: 'https://example.test/existing/index.min.json',
    ),
  ];
}
