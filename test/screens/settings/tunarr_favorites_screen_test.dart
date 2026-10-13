import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/tunarr/tunarr_channel.dart';
import 'package:plezy/providers/tunarr_account_provider.dart';
import 'package:plezy/screens/settings/tunarr_favorites_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

/// The picker is the only way to favourite a GalTV channel, so the two things a
/// viewer can notice are pinned here: the search actually narrows the list, and a
/// star tap lands in the store the Home shelf reads.
void main() {
  setUp(() {
    resetSharedPreferencesForTest();
  });

  final channels = const [
    TunarrChannel(id: 'ch-1', name: 'Military History', number: '1'),
    TunarrChannel(id: 'ch-2', name: 'COMEDY play', number: '2'),
    TunarrChannel(id: 'ch-12', name: 'Sci-Fi', number: '12'),
  ];

  Future<void> pumpPicker(WidgetTester tester) async {
    await SettingsService.getInstance();
    await tester.pumpWidget(
      ChangeNotifierProvider<TunarrAccountProvider>(
        create: (_) => TunarrAccountProvider(),
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: TunarrFavoritesScreen(channelLoader: () async => channels),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists every channel, sorted by number', (tester) async {
    await pumpPicker(tester);

    expect(find.text('1 · Military History'), findsOneWidget);
    expect(find.text('2 · COMEDY play'), findsOneWidget);
    expect(find.text('12 · Sci-Fi'), findsOneWidget);
  });

  testWidgets('filters by title and by number prefix', (tester) async {
    await pumpPicker(tester);

    await tester.enterText(find.byType(TextField), 'comedy');
    await tester.pumpAndSettle();
    expect(find.text('2 · COMEDY play'), findsOneWidget);
    expect(find.text('1 · Military History'), findsNothing);

    // A number matches on prefix, so `1` keeps channel 1 and channel 12.
    await tester.enterText(find.byType(TextField), '1');
    await tester.pumpAndSettle();
    expect(find.text('1 · Military History'), findsOneWidget);
    expect(find.text('12 · Sci-Fi'), findsOneWidget);
    expect(find.text('2 · COMEDY play'), findsNothing);
  });

  testWidgets('a star tap writes the channel id into the favourites store', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('tunarr-favorite-ch-2')));
    await tester.pumpAndSettle();

    expect(SettingsService.instance.read(SettingsService.galtvFavoriteChannelIds), ['ch-2']);

    await tester.tap(find.byKey(const ValueKey('tunarr-favorite-ch-2')));
    await tester.pumpAndSettle();
    expect(SettingsService.instance.read(SettingsService.galtvFavoriteChannelIds), isEmpty);
  });

  testWidgets('an empty result set says so', (tester) async {
    await pumpPicker(tester);

    await tester.enterText(find.byType(TextField), 'no such channel');
    await tester.pumpAndSettle();

    expect(find.text('No channels match'), findsOneWidget);
  });
}
