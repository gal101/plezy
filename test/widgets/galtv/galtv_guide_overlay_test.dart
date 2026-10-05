import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/galtv/galtv_guide_overlay.dart';

/// Fixtures shaped like a real Tunarr lineup: a long feature, a short `flex`
/// break, and a normal programme — the mix that has to stay legible.
GalTvGuideRow _row(
  String id,
  String number,
  String name, {
  required bool current,
  required DateTime now,
  String? logoUrl,
}) => GalTvGuideRow(
  channelId: id,
  channelNumber: number,
  channelName: name,
  logoUrl: logoUrl,
  entries: [
        GalTvGuideEntry(
          title: 'Operation Mincemeat',
          start: now.subtract(const Duration(hours: 2)),
          stop: now.add(const Duration(minutes: 1)),
          isPlayable: true,
          isCurrent: current,
        ),
        GalTvGuideEntry(
          title: 'Commercial Break',
          start: now.add(const Duration(minutes: 1)),
          stop: now.add(const Duration(minutes: 11)),
          isPlayable: false,
          isCurrent: false,
        ),
        GalTvGuideEntry(
          title: 'People We Meet on Vacation',
          start: now.add(const Duration(minutes: 11)),
          stop: now.add(const Duration(minutes: 131)),
          isPlayable: true,
          isCurrent: false,
        ),
        GalTvGuideEntry(
          title: 'Truth & Treason',
          start: now.add(const Duration(minutes: 131)),
          stop: now.add(const Duration(minutes: 191)),
          isPlayable: true,
          isCurrent: false,
        ),
      ],
    );

Widget _app({
  required List<GalTvGuideRow> rows,
  required String? currentChannelId,
  void Function(String channelId)? onSelectChannel,
  String? channelLogoUrl,
}) => MaterialApp(
  theme: monoTheme(dark: true),
  home: Scaffold(
    body: GalTvGuideOverlay(
      rows: rows,
      isLoading: false,
      error: null,
      currentChannelId: currentChannelId,
      channelLabel: 'CH 1 · War Movies',
      channelLogoUrl: channelLogoUrl,
      isSwitching: false,
      onSelectChannel: onSelectChannel,
      onClose: () {},
      onRetry: () {},
    ),
  ),
);

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets('marks the tuned channel and its programme, once each', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      _app(
        rows: [
          _row('war', '1', 'War Movies', current: true, now: now),
          _row('comedy', '2', 'Comedy', current: false, now: now),
        ],
        currentChannelId: 'war',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Watching'), findsOneWidget, reason: 'only the tuned channel is marked');
    expect(find.text('NOW'), findsOneWidget, reason: 'only the airing programme is marked');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tap on another channel reports that channel id', (tester) async {
    final now = DateTime.now();
    final tapped = <String>[];
    await tester.pumpWidget(
      _app(
        rows: [
          _row('war', '1', 'War Movies', current: true, now: now),
          _row('comedy', '2', 'Comedy', current: false, now: now),
        ],
        currentChannelId: 'war',
        onSelectChannel: tapped.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Comedy'));
    await tester.pump();

    expect(tapped, ['comedy']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lays out without overflow at desktop and TV sizes', (tester) async {
    final now = DateTime.now();
    for (final size in const [Size(1280, 720), Size(1568, 906), Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(
          rows: [
            _row('war', '1', 'War Movies', current: true, now: now),
            _row('comedy', '2', 'Comedy', current: false, now: now),
          ],
          currentChannelId: 'war',
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow at $size');
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wrapping title on the tuned cell keeps two full lines', (tester) async {
    final now = DateTime.now();
    const longTitle = 'The Wrecking Crew Rides Again Tonight';
    await tester.pumpWidget(
      _app(
        rows: [
          GalTvGuideRow(
            channelId: 'comedy',
            channelNumber: '2',
            channelName: 'Comedy',
            entries: [
              GalTvGuideEntry(
                title: longTitle,
                // A short airing → a narrow cell → the title has to wrap.
                start: now.subtract(const Duration(minutes: 5)),
                stop: now.add(const Duration(minutes: 15)),
                isPlayable: true,
                isCurrent: true,
              ),
            ],
          ),
        ],
        currentChannelId: 'comedy',
      ),
    );
    await tester.pumpAndSettle();

    final titleRect = tester.getRect(find.text(longTitle));
    final timeRect = tester.getRect(find.textContaining('–'));

    // The regression: the title used to get ~one line of height while painting
    // two, so the second line drew over the time row and the cell read as
    // mangled text. Two lines at fontSize 14 * height 1.1 is ~31px.
    expect(
      titleRect.height,
      greaterThanOrEqualTo(30),
      reason: 'a one-line-high box means the second line will paint over the time row',
    );
    expect(titleRect.bottom, lessThanOrEqualTo(timeRect.top + 0.5), reason: 'the title must end above the time row');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the panel owns almost the whole screen and leaves a video strip', (tester) async {
    final now = DateTime.now();
    for (final size in const [Size(1280, 720), Size(1568, 906), Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(
          rows: [
            _row('war', '1', 'War Movies', current: true, now: now),
            _row('comedy', '2', 'Comedy', current: false, now: now),
          ],
          currentChannelId: 'war',
        ),
      );
      await tester.pumpAndSettle();

      final panel = tester.getRect(find.ancestor(of: find.text('Guide'), matching: find.byType(Material)).first);
      final uncovered = size.width - panel.width;

      expect(panel.width / size.width, greaterThan(0.85), reason: 'the guide should own most of the screen at $size');
      expect(uncovered, greaterThanOrEqualTo(48.0), reason: 'a strip of picture must stay visible at $size');
      expect(uncovered, lessThanOrEqualTo(200.0), reason: 'the strip must stay a strip, not a column, at $size');
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the fitted grid fits the whole window inside the panel', (tester) async {
    // Six half-hours = a 3 h window, all lengths below the min/max clamps, so the
    // fitted scale should land the last cell exactly on the panel's edge.
    final now = DateTime.now();
    final entries = [
      for (var i = 0; i < 6; i++)
        GalTvGuideEntry(
          title: 'Programme ${i + 1}',
          start: now.add(Duration(minutes: 30 * i)),
          stop: now.add(Duration(minutes: 30 * (i + 1))),
          isPlayable: true,
          isCurrent: i == 0,
        ),
    ];

    tester.view.physicalSize = const Size(1568, 906);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        rows: [
          GalTvGuideRow(channelId: 'war', channelNumber: '1', channelName: 'War Movies', entries: entries),
        ],
        currentChannelId: 'war',
      ),
    );
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.ancestor(of: find.text('Guide'), matching: find.byType(Material)).first);
    final lastCell = tester.getRect(
      find.ancestor(of: find.text('Programme 6'), matching: find.byType(Container)).first,
    );

    final slack = panel.right - lastCell.right;
    expect(slack, greaterThanOrEqualTo(0), reason: 'the window must not overflow the panel');
    expect(slack, lessThanOrEqualTo(24), reason: 'and must not leave a dead band either');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 12 h window fills the panel and scrolls instead of shrinking', (tester) async {
    // 24 half-hours = the 12 h the tab fetches.
    final now = DateTime.now();
    final entries = [
      for (var i = 0; i < 24; i++)
        GalTvGuideEntry(
          title: 'Programme ${i + 1}',
          start: now.add(Duration(minutes: 30 * i)),
          stop: now.add(Duration(minutes: 30 * (i + 1))),
          isPlayable: true,
          isCurrent: i == 0,
        ),
    ];

    tester.view.physicalSize = const Size(1568, 906);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        rows: [
          GalTvGuideRow(channelId: 'war', channelNumber: '1', channelName: 'War Movies', entries: entries),
        ],
        currentChannelId: 'war',
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getRect(find.ancestor(of: find.text('Programme 1'), matching: find.byType(Container)).first);
    final second = tester.getRect(find.ancestor(of: find.text('Programme 2'), matching: find.byType(Container)).first);

    // 12 h cannot fit a 1568 px window legibly, so the scale stops at its floor:
    // a 30-min cell keeps its ~102 px (plus the 6 px gap) instead of shrinking to
    // squeeze the whole window in.
    expect(
      second.left - first.left,
      greaterThanOrEqualTo(96.0),
      reason: 'cells must not shrink below the readable floor',
    );

    final fades = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((box) => (box.decoration as BoxDecoration).gradient != null)
        .length;
    expect(fades, 1, reason: 'the window overflows, so the row shows its scroll-edge fade');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tuning back to the first channel leaves no highlight on the second', (tester) async {
    final now = DateTime.now();
    final rows = [
      _row('war', '1', 'War Movies', current: true, now: now),
      _row('comedy', '2', 'Comedy', current: false, now: now),
    ];

    // Watching channel 2 with the guide open, having just tapped its row — so
    // focus sits on that row. `onSelectChannel` mirrors a live session, where
    // rows are focusable and the guide can switch channels.
    await tester.pumpWidget(_app(rows: rows, currentChannelId: 'comedy', onSelectChannel: (_) {}));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Comedy'));
    await tester.pumpAndSettle();

    // ...then tuning back to channel 1, guide still up. Channel 2 must lose every
    // part of the tuned look; a lingering highlight there is the owner's report.
    await tester.pumpWidget(_app(rows: rows, currentChannelId: 'war', onSelectChannel: (_) {}));
    await tester.pumpAndSettle();

    final primary = monoTheme(dark: true).colorScheme.primary;
    final rowDecorations = tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .map((container) => container.decoration! as BoxDecoration)
        .toList();
    expect(rowDecorations, hasLength(2), reason: 'one decorated container per channel row');

    expect(rowDecorations[1].color, Colors.transparent, reason: 'the untuned row must not keep a tint');
    expect(
      (rowDecorations[1].border! as Border).top.color.toARGB32(),
      isNot(primary.toARGB32()),
      reason: 'only the tuned row may wear the accent colour',
    );

    final warRow = tester.widget<InkWell>(
      find.ancestor(of: find.text('War Movies'), matching: find.byType(InkWell)).first,
    );
    final comedyRow = tester.widget<InkWell>(
      find.ancestor(of: find.text('Comedy'), matching: find.byType(InkWell)).first,
    );
    expect(warRow.focusNode?.hasFocus, isTrue, reason: 'the focus ring follows the tuned channel');
    expect(comedyRow.focusNode?.hasFocus, isFalse, reason: 'the row we just left must not stay focused');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the tuned row takes focus even when the grid lands after the layer opens', (tester) async {
    final now = DateTime.now();
    final rows = [
      _row('war', '1', 'War Movies', current: true, now: now),
      _row('comedy', '2', 'Comedy', current: false, now: now),
    ];

    // First frame: the schedule is still loading, so there is no row to focus.
    // The close button is the only focus target — that must not be where focus
    // stays once the rows arrive (the owner's report: opening the guide always
    // left the ring on the panel's X, not on the channel on screen).
    await tester.pumpWidget(_app(rows: const [], currentChannelId: 'war', onSelectChannel: (_) {}));
    await tester.pumpAndSettle();

    // ...then the rows land.
    await tester.pumpWidget(_app(rows: rows, currentChannelId: 'war', onSelectChannel: (_) {}));
    await tester.pumpAndSettle();

    final warRow = tester.widget<InkWell>(
      find.ancestor(of: find.text('War Movies'), matching: find.byType(InkWell)).first,
    );
    expect(warRow.focusNode?.hasFocus, isTrue, reason: 'the tuned row must take focus once the grid appears');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a channel logo shows in its row and in the header, and not for a channel without one', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      _app(
        rows: [
          _row('war', '1', 'War Movies', current: true, now: now, logoUrl: 'https://cdn.example/war.png'),
          _row('comedy', '2', 'Comedy', current: false, now: now),
        ],
        currentChannelId: 'war',
        channelLogoUrl: 'https://cdn.example/war.png',
      ),
    );
    await tester.pumpAndSettle();

    // The header logo plus the tuned channel's row logo. The URL never resolves
    // under the test HTTP client; the errorBuilder keeps it a sized gap rather
    // than a broken tile, which is exactly the production fallback.
    expect(find.byType(Image), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox());
  });
}
