import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/widgets/galtv/galtv_up_next_hint.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';
import 'package:plezy/widgets/video_controls/widgets/track_chapter_controls.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';
import '../test_helpers/watch_together_fakes.dart';

/// The TV Guide and "Sync to live" buttons belong to a GalTV session only —
/// they are meaningless (and the guide has nothing to show) on an ordinary
/// movie or episode. Guards the leak the owner reported: a GalTV control
/// showing up in the normal player.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late FakeSyncPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    settings = await SettingsService.getInstance();
    PlatformDetector.debugSetIsDesktopOSOverride(false);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeSyncPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
  });

  tearDown(() async {
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await player.dispose();
    await database.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    required bool galTv,
    bool guideVisible = false,
    bool galTvOnFiller = false,
    bool desktop = false,
    VoidCallback? onShowGalTvUpNext,
    GalTvUpNext? upNext,
  }) async {
    if (desktop) PlatformDetector.debugSetIsDesktopOSOverride(true);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          // The chrome branches on the *theme* platform (and on the desktop
          // override), so a desktop case has to say so in both places.
          theme: ThemeData(
            platform: desktop ? TargetPlatform.windows : TargetPlatform.android,
            extensions: const [testMonoTokens],
          ),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'galtv-buttons'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
                isGalTv: galTv,
                galTvOnFiller: galTvOnFiller,
                onShowGalTvUpNext: onShowGalTvUpNext,
                galTvUpNext: upNext == null ? null : ValueNotifier<GalTvUpNext?>(upNext),
                onResyncGalTv: galTv ? () {} : null,
                galTvGuideVisible: galTv ? ValueNotifier<bool>(guideVisible) : null,
                onToggleGalTvGuide: galTv ? () {} : null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TrackChapterControls), findsOneWidget);
  }

  testWidgets('a GalTV session shows the sync-to-live and guide buttons', (tester) async {
    await pump(tester, galTv: true);
    expect(find.byIcon(Symbols.sync_rounded), findsOneWidget, reason: 'sync-to-live is a GalTV control');
    expect(find.byIcon(Symbols.tv_rounded), findsOneWidget, reason: 'the TV Guide toggle is a GalTV control');
  });

  testWidgets('an ordinary session shows neither GalTV button', (tester) async {
    await pump(tester, galTv: false);
    expect(find.byIcon(Symbols.sync_rounded), findsNothing, reason: 'no channel to sync to');
    expect(find.byIcon(Symbols.tv_rounded), findsNothing, reason: 'no guide to show');
  });

  /// The owner's ask, 2026-10-09: *"above the up next button while watching ads
  /// can we add the Text Logo of the upcoming Movie/TVShow? so you can always see
  /// whats next anyway but in a minimized form, with the start time too"* — so the
  /// slot carries the next programme continuously, not only once the slate is
  /// opened.
  testWidgets('a filler shows what is next, in miniature, above the UP NEXT button', (tester) async {
    final upNext = GalTvUpNext(
      channelId: 'ch-4',
      title: 'The Head',
      startsAt: DateTime.now().add(const Duration(minutes: 20)),
      ratingKey: '3769',
    );

    await pump(
      tester,
      galTv: true,
      desktop: true,
      galTvOnFiller: true,
      onShowGalTvUpNext: () {},
      upNext: upNext,
    );

    expect(find.byType(GalTvUpNextHint), findsOneWidget);
    expect(find.text('The Head'), findsOneWidget, reason: 'the payload title, until Plex answers');
    expect(find.textContaining('Starts at'), findsOneWidget);
    expect(find.text('UP NEXT'), findsOneWidget, reason: 'the button is still there, underneath');
    // The hint sits above the button, not beside or over it.
    expect(
      tester.getBottomLeft(find.byType(GalTvUpNextHint)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('UP NEXT')).dy),
    );

    // …and on an ordinary programme the slot is only the skip prompt: no hint.
    await pump(tester, galTv: true, desktop: true, galTvOnFiller: false, upNext: upNext);
    expect(find.byType(GalTvUpNextHint), findsNothing);
  });

  /// The owner's "ad player": while a filler is on screen the chrome keeps only
  /// what belongs to the *channel* — play/pause, the channel steps, the guide and
  /// UP NEXT — and drops every affordance of the ad's own playback session, plus
  /// every way of seeking it.
  testWidgets('an ad drops the settings, track and seek controls and locks the timeline', (tester) async {
    await pump(tester, galTv: true, desktop: true);
    // Baseline: a normal GalTV programme has all of them.
    expect(find.byIcon(Symbols.tune_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.replay_10_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.forward_10_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.play_arrow_rounded), findsOneWidget);
    expect(tester.widget<TimelineSlider>(find.byType(TimelineSlider)).enabled, isTrue);

    await pump(tester, galTv: true, desktop: true, galTvOnFiller: true);

    expect(find.byIcon(Symbols.tune_rounded), findsNothing, reason: 'no playback settings for an ad');
    expect(find.byIcon(Symbols.audiotrack_rounded), findsNothing, reason: 'no track picker for an ad');
    expect(find.byIcon(Symbols.subtitles_rounded), findsNothing);
    expect(find.byIcon(Symbols.subtitles_off_rounded), findsNothing);
    expect(find.byIcon(Symbols.replay_10_rounded), findsNothing, reason: 'an ad cannot be skipped back');
    expect(find.byIcon(Symbols.forward_10_rounded), findsNothing, reason: 'an ad cannot be skipped forward');
    expect(
      tester.widget<TimelineSlider>(find.byType(TimelineSlider)).enabled,
      isFalse,
      reason: 'the seek bar must not accept a drag while an ad plays',
    );

    // The channel controls are untouched: the viewer can still leave the ad.
    expect(find.byIcon(Symbols.tv_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.sync_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.play_arrow_rounded), findsNothing, reason: 'an ad cannot be stopped');
    expect(find.byIcon(Symbols.pause_rounded), findsNothing);
  });

  testWidgets('Select is left to the guide while the TV Guide layer is up', (tester) async {
    await pump(tester, galTv: true, guideVisible: true);
    // The layer's rows are a separate focus branch, so while the grid is still
    // fetching (or otherwise unfocused) the player surface is what holds focus.
    // Answering Select there is "raise the chrome onto Play/Pause and toggle
    // playback" — the owner's "it pauses the clip and the guide loses focus".
    await tester.pump(const Duration(milliseconds: 50));
    player.commandLog.clear();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      player.commandLog.where((command) => command == 'play' || command == 'pause'),
      isEmpty,
      reason: 'Select belongs to the guide while it is up, never to the player surface',
    );

    // Drain the chrome's auto-hide timer the key press armed.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
