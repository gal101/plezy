import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/widgets/galtv/galtv_up_next_overlay.dart';

/// The break slate is the only thing on screen while a channel has nothing to
/// play, so it must show what it exists for: which channel, what is coming, when
/// it starts, and — once Plex answers — what it looks like.
///
/// These pin the *contract* only. Anything about the backdrop's drift, the
/// hourglass's rotation or the exact scrim is presentation, it changes with every
/// design pass, and a test that pins it costs more than it catches.
///
/// The time is Tunarr's slot time formatted for the viewer, hence the loose match
/// on "Starts at", which pins "a time is shown" without pinning the test
/// machine's timezone.
void main() {
  GalTvUpNext upNext() => GalTvUpNext(
    channelId: 'ch-1',
    title: 'Iron Man',
    startsAt: DateTime.utc(2026, 10, 7, 20, 3),
    ratingKey: '466',
  );

  /// Mounts the slate and guarantees the tree is disposed before the test ends —
  /// the backdrop drifts forever, so a test that just walks away would leave a
  /// ticker running past its own teardown.
  Future<void> pumpSlate(WidgetTester tester, Widget slate) async {
    await tester.pumpWidget(MaterialApp(home: slate));
    // The artwork fetch resolves a microtask after the first frame, and the slate
    // needs that rebuild before any assertion about it can be honest.
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  testWidgets('names the programme and prints its start time', (tester) async {
    await pumpSlate(tester, GalTvUpNextOverlay(upNext: upNext(), channelLabel: 'CH 1 · Tom Cruise'));

    expect(find.text('Iron Man'), findsOneWidget);
    expect(find.text('CH 1 · Tom Cruise'), findsOneWidget);
    expect(find.textContaining('Starts at'), findsOneWidget);
  });

  testWidgets('renders without a channel label or logo', (tester) async {
    await pumpSlate(tester, GalTvUpNextOverlay(upNext: upNext()));

    expect(find.text('Iron Man'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// The tab opens its channel list from this card. A host with no list to open
  /// passes nothing and must get a card with no dead affordances on it.
  testWidgets('offers a channels shortcut only when the host provides one', (tester) async {
    await pumpSlate(tester, GalTvUpNextOverlay(upNext: upNext()));
    expect(find.text('Channels'), findsNothing);

    var opened = 0;
    await pumpSlate(tester, GalTvUpNextOverlay(upNext: upNext(), onBrowseChannels: () => opened++));

    expect(find.text('Channels'), findsOneWidget);
    await tester.tap(find.text('Channels'));
    expect(opened, 1);
  });

  /// The slate paints over the player's own chrome, so on a TV — where there is
  /// no `I` key to press — these two are the only way to change channel or open
  /// the guide while a break is on screen.
  testWidgets('carries the player channel and guide affordances', (tester) async {
    final steps = <int>[];
    var guideOpened = 0;
    await pumpSlate(
      tester,
      GalTvUpNextOverlay(upNext: upNext(), onChannelStep: steps.add, onOpenGuide: () => guideOpened++),
    );

    expect(find.text('Channel −'), findsOneWidget);
    expect(find.text('Channel +'), findsOneWidget);
    expect(find.text('TV Guide'), findsOneWidget);

    await tester.tap(find.text('Channel +'));
    await tester.tap(find.text('Channel −'));
    await tester.tap(find.text('TV Guide'));

    expect(steps, [1, -1]);
    expect(guideOpened, 1);
  });

  /// The player binds left/right to **seek**, and that binding is an *ancestor* of
  /// this layer, so the arrows reached the transport instead of the slate's own
  /// buttons — the owner's report: *"pressing arrows on my keyboard seeks the
  /// credits +10 instead of navigating the up next buttons"*.
  ///
  /// The host below stands in for the player: it consumes the arrows exactly as the
  /// transport does, so a regression shows up as a fired seek rather than as a
  /// silent no-op.
  testWidgets('takes the ring and owns the arrow keys', (tester) async {
    var seeks = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowLeft): _HostSeekIntent(),
            SingleActivator(LogicalKeyboardKey.arrowRight): _HostSeekIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _HostSeekIntent: CallbackAction<_HostSeekIntent>(
                onInvoke: (_) {
                  seeks++;
                  return null;
                },
              ),
            },
            child: GalTvUpNextOverlay(upNext: upNext(), onChannelStep: (_) {}, onOpenGuide: () {}),
          ),
        ),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pump();
    await tester.pump();

    final prevChannel = find.byKey(const ValueKey<String>('galtv-slate-prev-channel'));
    final nextChannel = find.byKey(const ValueKey<String>('galtv-slate-next-channel'));
    final guide = find.byKey(const ValueKey<String>('galtv-slate-guide'));

    // The ring starts on TV Guide — the owner's call (2026-10-09), and the one
    // action a viewer on a break cannot reach any other way on a TV.
    expect(tester.widget<OutlinedButton>(guide).focusNode?.hasFocus, isTrue,
        reason: 'the layer must claim the ring when it appears, on the guide action');

    // LEFT from the guide must reach CH + and then CH −, which is the owner's
    // report; it used to fall through to the player and start seeking.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(nextChannel).focusNode?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(prevChannel).focusNode?.hasFocus, isTrue);

    // …and back the other way.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(nextChannel).focusNode?.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(guide).focusNode?.hasFocus, isTrue);

    // At the left edge the scope holds the ring: traversal finds no candidate and
    // the player chrome below (which is held visible for the slate's lifetime)
    // must not take it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(seeks, 0, reason: 'the slate must swallow the arrows rather than let the player seek');
    expect(tester.widget<OutlinedButton>(prevChannel).focusNode?.hasFocus, isTrue,
        reason: 'arrows must never escape the slate into the player chrome');
  });

  /// The guide draws over the slate and holds the ring while it is up. When it
  /// closes, the ring must come back here — the owner's report, 2026-10-09:
  /// *"watching ad -> up next screen -> guide button -> select same channel ->
  /// guide closes -> still on Up Next screen, no more dpad, no more highlighted
  /// button"*. Picking the **same** channel resolves to no switch at all
  /// (`_tuneGalTvChannel` returns early), so the payload never changes and nothing
  /// else would re-claim.
  testWidgets('takes the ring back when the guide closes over it', (tester) async {
    final guideVisible = ValueNotifier<bool>(false);
    addTearDown(guideVisible.dispose);

    await pumpSlate(
      tester,
      GalTvUpNextOverlay(
        upNext: upNext(),
        onChannelStep: (_) {},
        onOpenGuide: () {},
        guideVisible: guideVisible,
      ),
    );
    final guide = find.byKey(const ValueKey<String>('galtv-slate-guide'));
    expect(tester.widget<OutlinedButton>(guide).focusNode?.hasFocus, isTrue);

    // The guide opens and takes the ring: in the app its own scope node holds it,
    // and the slate's nodes are left behind with nothing focused.
    guideVisible.value = true;
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(tester.widget<OutlinedButton>(guide).focusNode?.hasFocus, isFalse);

    // …and closes again.
    guideVisible.value = false;
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<OutlinedButton>(guide).focusNode?.hasFocus,
      isTrue,
      reason: 'the slate is still up and must own the ring again',
    );
  });

  /// A slate raised over the *credits* sits on top of something still playing, so
  /// it can be waved away. A slate filling a *gap* is the channel's own state —
  /// closing it would leave nothing at all — so the host says which by passing a
  /// callback or not.
  testWidgets('offers a close button only when the host can dismiss it', (tester) async {
    await pumpSlate(tester, GalTvUpNextOverlay(upNext: upNext()));
    expect(find.byIcon(Symbols.close_rounded), findsNothing);

    var dismissed = 0;
    await pumpSlate(tester, GalTvUpNextOverlay(upNext: upNext(), onDismiss: () => dismissed++));

    expect(find.byIcon(Symbols.close_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    expect(dismissed, 1);
  });

  /// What the slate is really for on a real channel: the next film's own artwork
  /// and blurb, resolved through Plex rather than Tunarr.
  testWidgets('paints the programme Plex resolved, not just its name', (tester) async {
    const summary = 'A billionaire engineer is forced to confront the legacy of the weapons he built.';
    await pumpSlate(
      tester,
      GalTvUpNextOverlay(
        upNext: upNext(),
        channelLabel: 'CH 1 · Tom Cruise',
        mediaResolver: (ratingKey) async {
          expect(ratingKey, '466');
          return const GalTvUpNextMedia(
            title: 'Iron Man',
            summary: summary,
            year: 2008,
            contentRating: 'PG-13',
            duration: Duration(hours: 2, minutes: 6),
            logoPath: '/library/metadata/466/clearLogo',
            artPath: '/library/metadata/466/art',
          );
        },
      ),
    );

    expect(find.text(summary), findsOneWidget);
    expect(find.text('2008  ·  PG-13  ·  2h 06m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// The slate is bottom-anchored chrome, so its content grows *upwards* and the
  /// only way it can break is by running off the top of the screen. The tallest
  /// payload it can be handed — a TV episode, a three-line blurb, and every
  /// affordance at once — still has to fit 720p, the smallest screen it runs on.
  testWidgets('the tallest payload fits a 720p screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpSlate(
      tester,
      GalTvUpNextOverlay(
        upNext: upNext(),
        channelLabel: 'CH 4 · TEST2',
        onChannelStep: (_) {},
        onOpenGuide: () {},
        mediaResolver: (ratingKey) async => const GalTvUpNextMedia(
          title: 'Severance',
          subtitle: 'Good News About Hell',
          episodeLabel: 'S01E01',
          summary:
              'Mark leads a team of office workers whose memories have been surgically divided between their work '
              'and personal lives, and who begin to discover a terrifying truth about the job they cannot leave.',
          year: 2022,
          contentRating: 'TV-MA',
          duration: Duration(minutes: 57),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('S01E01  ·  Good News About Hell'), findsOneWidget);
    expect(find.text('TV Guide'), findsOneWidget);
  });

  /// A season and episode number is the one thing a viewer needs to know which
  /// episode is next — and it is TV-only, because a film has nothing to number.
  testWidgets('numbers an episode and leaves a film unnumbered', (tester) async {
    await pumpSlate(
      tester,
      GalTvUpNextOverlay(
        upNext: upNext(),
        mediaResolver: (ratingKey) async => const GalTvUpNextMedia(
          title: 'Severance',
          subtitle: 'Good News About Hell',
          episodeLabel: 'S01E01',
        ),
      ),
    );
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('S01E01  ·  Good News About Hell'), findsOneWidget);

    await pumpSlate(
      tester,
      GalTvUpNextOverlay(
        upNext: upNext(),
        mediaResolver: (ratingKey) async => const GalTvUpNextMedia(title: 'Iron Man'),
      ),
    );
    expect(find.textContaining('S01E01'), findsNothing);
  });

  /// The normal case for a filler and for anything in an `Other Videos` library:
  /// Plex has no `clearLogo` (it is agent artwork), so the title stands in. That
  /// is a fallback, not a failure.
  testWidgets('falls back to the title when Plex has no artwork for the item', (tester) async {
    await pumpSlate(
      tester,
      GalTvUpNextOverlay(
        upNext: upNext(),
        mediaResolver: (ratingKey) async => const GalTvUpNextMedia(title: 'Iron Man', summary: 'A quick break.'),
      ),
    );

    expect(find.text('Iron Man'), findsOneWidget);
    expect(find.text('A quick break.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// No Plex client and no resolver is the pre-artwork slate, and it must stay a
  /// supported state: the player can be showing a channel whose Plex server is
  /// unreachable, and a slate is never worth an error screen.
  testWidgets('survives a resolver that returns nothing and one that throws', (tester) async {
    await pumpSlate(
      tester,
      GalTvUpNextOverlay(upNext: upNext(), mediaResolver: (ratingKey) async => null),
    );
    expect(find.text('Iron Man'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpSlate(
      tester,
      GalTvUpNextOverlay(upNext: upNext(), mediaResolver: (ratingKey) async => throw StateError('plex down')),
    );
    expect(find.text('Iron Man'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Stands in for the player's arrow→seek binding.
///
/// That binding lives on an **ancestor** of the slate, so it is exactly what the
/// arrows used to hit. If the slate ever stops claiming them, this fires.
class _HostSeekIntent extends Intent {
  const _HostSeekIntent();
}
