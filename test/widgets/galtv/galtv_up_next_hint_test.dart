import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/galtv/galtv_up_next_hint.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

/// The compact "what is next" line that rides above the UP NEXT button while an
/// ad plays. Its whole job is to be readable at a glance: the next programme's own
/// wordmark, and when it starts.
void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  GalTvUpNext upNext() => GalTvUpNext(
    channelId: 'ch-4',
    title: 'The Head',
    startsAt: DateTime.now().add(const Duration(minutes: 20)),
    ratingKey: '3769',
  );

  Future<void> pumpHint(
    WidgetTester tester, {
    Future<GalTvUpNextMedia?> Function(String ratingKey)? mediaResolver,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(body: Center(child: GalTvUpNextHint(upNext: upNext(), mediaResolver: mediaResolver))),
      ),
    );
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  testWidgets('draws the next programme\'s wordmark and its start time', (tester) async {
    await pumpHint(
      tester,
      mediaResolver: (ratingKey) async => const GalTvUpNextMedia(
        title: 'The Head',
        logoPath: '/library/metadata/3769/clearLogo',
      ),
    );

    final logo = tester.widget<ClearLogoImage>(find.byType(ClearLogoImage));
    expect(logo.logoPath, '/library/metadata/3769/clearLogo');
    expect(find.textContaining('Starts at'), findsOneWidget);
  });

  /// A logo is agent artwork: an item in an `Other Videos` library never has one,
  /// and neither does anything Plex has not matched. The hint must still say what
  /// is coming rather than rendering as an empty pill.
  testWidgets('falls back to the programme title when Plex has no logo', (tester) async {
    await pumpHint(
      tester,
      mediaResolver: (ratingKey) async => const GalTvUpNextMedia(title: 'full'),
    );

    expect(tester.widget<ClearLogoImage>(find.byType(ClearLogoImage)).logoPath, isNull);
    expect(find.text('full'), findsOneWidget);
    expect(find.textContaining('Starts at'), findsOneWidget);
  });

  testWidgets('shows the schedule\'s own title when nothing resolves at all', (tester) async {
    // No Plex client and no resolver answer — the worst case, and still not blank.
    await pumpHint(tester, mediaResolver: (ratingKey) async => null);

    expect(find.text('The Head'), findsOneWidget);
    expect(find.textContaining('Starts at'), findsOneWidget);
  });

  testWidgets('never swallows a tap meant for the picture', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: Center(
              child: GalTvUpNextHint(upNext: upNext(), mediaResolver: (ratingKey) async => null),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(GalTvUpNextHint));
    expect(taps, 1, reason: 'the hint is informational; the UP NEXT pill under it is the affordance');
  });
}
