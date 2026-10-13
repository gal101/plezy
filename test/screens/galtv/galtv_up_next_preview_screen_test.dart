import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/galtv/galtv_guide.dart';
import 'package:plezy/screens/galtv/galtv_up_next_preview_screen.dart';

/// `previewMediaFor` is the one piece of the preview screen that carries
/// meaning: it decides what each scenario does to the payload Plex really
/// returned. Kept pure and top-level precisely so it can be checked here,
/// without a Tunarr session, a Plex client, or a widget binding.
///
/// The scenario switcher is only honest if these four cases are: "no logo" must
/// still show the blurb and metadata, and "long synopsis" must not quietly throw
/// the artwork away while it stretches the text.
void main() {
  const real = GalTvUpNextMedia(
    title: 'The Hunt for Red October',
    summary: 'A submarine captain heads for America.',
    year: 1990,
    contentRating: 'PG',
    duration: Duration(minutes: 135),
    logoPath: '/library/metadata/466/clearLogo',
    artPath: '/library/metadata/466/art',
  );

  group('previewMediaFor', () {
    test('live hands back exactly what Plex returned', () {
      expect(previewMediaFor(GalTvUpNextPreviewScenario.live, real), same(real));
    });

    test('noLogo drops the artwork but keeps the blurb and metadata', () {
      final result = previewMediaFor(GalTvUpNextPreviewScenario.noLogo, real)!;

      expect(result.logoPath, isNull);
      expect(result.artPath, isNull);
      expect(result.summary, real.summary);
      expect(result.year, real.year);
      expect(result.contentRating, real.contentRating);
      expect(result.duration, real.duration);
    });

    test('noMedia produces nothing to paint', () {
      expect(previewMediaFor(GalTvUpNextPreviewScenario.noMedia, real), isNull);
    });

    test('long keeps the artwork and replaces the summary with a longer one', () {
      final result = previewMediaFor(GalTvUpNextPreviewScenario.long, real)!;

      expect(result.logoPath, real.logoPath);
      expect(result.artPath, real.artPath);
      expect(result.summary, isNot(real.summary));
      expect(result.summary!.length, greaterThan(real.summary!.length));
    });
  });
}
