import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/galtv/galtv_favorites.dart';

/// The favourites list is keyed by Tunarr channel id, and the rules that matter
/// are the ones a viewer would notice: renaming a channel must not lose it,
/// deleting one must hide it, and a Tunarr that is merely unreachable must not
/// erase the list.
void main() {
  group('toggled', () {
    test('appends a new favourite and removes an existing one', () {
      expect(GalTvFavorites.toggled(const [], 'ch-1'), ['ch-1']);
      expect(GalTvFavorites.toggled(const ['ch-1'], 'ch-1'), isEmpty);
    });

    test('keeps favourite order and never duplicates', () {
      final first = GalTvFavorites.toggled(const [], 'ch-1');
      final second = GalTvFavorites.toggled(first, 'ch-2');
      expect(second, ['ch-1', 'ch-2']);
      expect(GalTvFavorites.toggled(second, 'ch-1'), ['ch-2']);
      // Re-favouriting lands at the end, which is also its place on the shelf.
      expect(GalTvFavorites.toggled(GalTvFavorites.toggled(second, 'ch-1'), 'ch-1'), ['ch-2', 'ch-1']);
    });
  });

  group('visible', () {
    test('keeps favourite order and drops ids the channel list no longer has', () {
      // 'ch-2' was deleted in Tunarr, or deleted and recreated under a new id.
      expect(GalTvFavorites.visible(const ['ch-1', 'ch-2', 'ch-3'], {'ch-3', 'ch-1'}), ['ch-1', 'ch-3']);
    });

    test('a channel renamed or renumbered in Tunarr keeps its favourite', () {
      // The stored value never carries a name or a number, so a rename is
      // invisible to the list: only the id is compared.
      const renamedButSameId = 'ch-1';
      expect(GalTvFavorites.visible(const ['ch-1'], {renamedButSameId}), ['ch-1']);
    });

    test('an unreachable Tunarr hides favourites without forgetting them', () {
      const stored = ['ch-1', 'ch-2'];
      // A failed load answers with nothing at all — the stored list must survive
      // it, or one outage would wipe what the viewer built by hand.
      expect(GalTvFavorites.visible(stored, const {}), isEmpty);
      expect(GalTvFavorites.visible(stored, {'ch-1', 'ch-2'}), stored);
    });
  });

  test('missing reports what is gone without touching the list', () {
    const stored = ['ch-1', 'ch-2'];
    expect(GalTvFavorites.missing(stored, {'ch-1'}), ['ch-2']);
    expect(stored, ['ch-1', 'ch-2'], reason: 'reporting must never mutate');
  });
}
