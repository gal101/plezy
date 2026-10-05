import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';
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

  Future<void> pump(WidgetTester tester, {required bool galTv}) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
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
                onResyncGalTv: galTv ? () {} : null,
                galTvGuideVisible: galTv ? ValueNotifier<bool>(false) : null,
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
}
