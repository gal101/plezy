import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/tunarr/tunarr_channel.dart';
import 'package:plezy/models/tunarr/tunarr_lineup.dart';
import 'package:plezy/services/galtv/galtv_home_shelves.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/cycling_media_backdrop.dart';
import 'package:plezy/widgets/tv_spotlight_background.dart';
import 'package:plezy/widgets/tv_spotlight_scaffold.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

MediaItem _item(String id) => testMediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: id);

MediaHub _hub(String id, List<MediaItem> items) =>
    MediaHub(id: id, title: id, type: 'movie', size: items.length, items: items);

/// Mounts the real dashboard spotlight over [item], the way the TV Home does.
Future<void> _pumpSpotlight(WidgetTester tester, MediaItem? item) async {
  await SettingsService.getInstance();
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            child: TvSpotlightBackground(
              item: item,
              client: null,
              allowNetwork: false,
              compact: true,
              contentTop: 80,
              contentBottom: 200,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(true);
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  test('spotlight controller cancels an intermediate debounced selection', () async {
    final first = _item('first');
    final second = _item('second');
    final controller = TvSpotlightController(settleDelay: const Duration(milliseconds: 10));
    addTearDown(controller.dispose);
    controller.value = first;

    controller.select(second);
    controller.select(first);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.value, same(first));
  });

  test('spotlight controller resolves valid selection or first hub item', () {
    final first = _item('first');
    final second = _item('second');
    final controller = TvSpotlightController(settleDelay: Duration.zero);
    addTearDown(controller.dispose);
    final hubs = [
      _hub('one', [first]),
      _hub('two', [second]),
    ];

    expect(controller.resolve(hubs), same(first));
    controller.select(second);
    expect(controller.resolve(hubs), same(second));

    controller.value = _item('removed');
    expect(controller.resolve(hubs), same(first));
  });

  test('spotlight controller resolves the latest item instance for a retained selection', () {
    final stale = _item('same');
    final refreshed = testMediaItem(id: 'same', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Updated');
    final controller = TvSpotlightController(settleDelay: Duration.zero);
    addTearDown(controller.dispose);
    controller.value = stale;

    expect(
      controller.resolve([
        _hub('one', [refreshed]),
      ]),
      same(refreshed),
    );
  });

  /// The owner's report, 2026-10-09: focusing a **GalTV** shelf card on the TV Home
  /// left the big backdrop block empty, while any other shelf's card previewed its
  /// movie with artwork, title and synopsis. The synthesized card simply did not
  /// carry what the shared preview reads — a server to resolve an artwork client
  /// from, and the hero path, synopsis and metadata the programme already had in
  /// the lineup.
  testWidgets('a GalTV channel card previews its airing programme', (tester) async {
    final base = DateTime.utc(2026, 10, 9, 20, 0);
    final shelves = buildGalTvHomeShelves(
      channels: [TunarrChannel(id: 'ch-1', number: '1', name: 'Military History')],
      lineups: [
        TunarrLineupChannel(
          id: 'ch-1',
          name: 'Military History',
          number: '1',
          slots: [
            TunarrLineupSlot(
              id: 'a',
              start: base.millisecondsSinceEpoch,
              stop: base.add(const Duration(hours: 2)).millisecondsSinceEpoch,
              duration: const Duration(hours: 2).inMilliseconds,
              type: 'content',
              program: const TunarrProgram(
                title: 'The King',
                externalId: '1561',
                type: 'movie',
                summary: 'Young Henry V encounters deceit, war and treachery.',
                year: 2019,
                contentRating: 'R',
              ),
            ),
          ],
        ),
      ],
      favoriteChannelIds: const {},
      plexServerId: '2b4de25a5218f319e362965a18218950772171af',
      now: base,
      allChannelsTitle: 'Live now',
      favoritesTitle: 'Favourite channels',
      subtitleFor: (channel) => 'CH ${channel.number} · ${channel.name}',
    );
    final card = shelves.single.items.single;

    await _pumpSpotlight(tester, card);

    expect(find.text('The King'), findsOneWidget, reason: 'the title, or its wordmark, heads the preview');
    expect(find.textContaining('Young Henry V'), findsOneWidget, reason: 'and the synopsis sits under it');
    expect(find.textContaining('2019'), findsOneWidget, reason: 'the metadata line still names the year');
    final backdrop = tester.widget<CyclingMediaBackdrop>(find.byType(CyclingMediaBackdrop));
    expect(
      backdrop.imagePaths,
      contains('/library/metadata/1561/art'),
      reason: 'the programme backdrop is what the preview paints',
    );
    expect(card.serverId, isNotNull, reason: 'the real screen resolves the artwork client from this');
  });
}
