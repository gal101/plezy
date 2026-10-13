import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/video_controls/widgets/skip_marker_button.dart';

/// The marker slot in the player chrome holds two different questions. On a
/// recording it is "do you want to skip this?"; in a GalTV session there is
/// nothing to skip — the intro *is* the broadcast, and there is no next episode
/// of a channel — so the same slot offers the schedule's next programme instead.
///
/// Pinned here because the labelling is the whole difference: the wrong label
/// sends the viewer looking for a skip that does not exist.
void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  MediaMarker marker({required bool credits, int endMs = 30000}) => MediaMarker(
    id: 1,
    type: credits ? 'credits' : 'intro',
    startTimeOffset: 0,
    endTimeOffset: endMs,
  );

  Widget app({
    required MediaMarker mediaMarker,
    required bool galTvUpNext,
    VoidCallback? onActivate,
  }) => MaterialApp(
    theme: monoTheme(dark: true),
    home: Scaffold(
      body: SkipMarkerButton(
        marker: mediaMarker,
        playerDuration: const Duration(minutes: 45),
        hasNextEpisode: false,
        isAutoSkipActive: false,
        shouldShowAutoSkip: false,
        autoSkipDelay: 10,
        autoSkipProgress: 0,
        focusNode: FocusNode(),
        galTvUpNext: galTvUpNext,
        onActivate: onActivate ?? () {},
        onFocusDown: () {},
      ),
    ),
  );

  testWidgets('a GalTV session is offered the next programme, never a skip', (tester) async {
    await tester.pumpWidget(app(mediaMarker: marker(credits: true), galTvUpNext: true));

    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.text('Skip Credits'), findsNothing);
  });

  /// Even a credits marker that sits at the very end of the file — the case that
  /// normally becomes "Next Episode" — stays the schedule's question in GalTV.
  testWidgets('the end-of-file credit case stays UP NEXT in a GalTV session', (tester) async {
    await tester.pumpWidget(
      app(mediaMarker: marker(credits: true, endMs: 45 * 60 * 1000), galTvUpNext: true),
    );

    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.text('Next Episode'), findsNothing);
  });

  testWidgets('an ordinary session keeps both skip prompts', (tester) async {
    await tester.pumpWidget(app(mediaMarker: marker(credits: true), galTvUpNext: false));
    expect(find.text('Skip Credits'), findsOneWidget);
    expect(find.text('UP NEXT'), findsNothing);

    await tester.pumpWidget(app(mediaMarker: marker(credits: false), galTvUpNext: false));
    expect(find.text('Skip Intro'), findsOneWidget);
  });

  /// A GalTV **filler** raises the same question with no marker at all: an ad is a
  /// break the viewer is sitting through, and "what is next" is what a break asks.
  /// This is the whole reason `marker` is nullable.
  testWidgets('renders without a marker at all for the GalTV filler slot', (tester) async {
    var activated = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: SkipMarkerButton(
            playerDuration: Duration.zero,
            hasNextEpisode: false,
            isAutoSkipActive: false,
            shouldShowAutoSkip: false,
            autoSkipDelay: 10,
            autoSkipProgress: 0,
            focusNode: FocusNode(),
            galTvUpNext: true,
            onActivate: () => activated++,
            onFocusDown: () {},
          ),
        ),
      ),
    );

    expect(find.text('UP NEXT'), findsOneWidget);
    await tester.tap(find.byType(SkipMarkerButton));
    expect(activated, 1);
  });

  testWidgets('activating the GalTV variant runs the host action', (tester) async {
    var activated = 0;
    await tester.pumpWidget(
      app(mediaMarker: marker(credits: true), galTvUpNext: true, onActivate: () => activated++),
    );

    await tester.tap(find.byType(SkipMarkerButton));

    expect(activated, 1);
  });
}
