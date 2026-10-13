import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_rating.dart';
import 'package:plezy/models/tunarr/tunarr_channel.dart';
import 'package:plezy/models/tunarr/tunarr_lineup.dart';
import 'package:plezy/services/galtv/galtv_home_shelves.dart';

/// The Home shelves are a pure projection of Tunarr's channel list and lineup:
/// which channels exist, what each is airing right now, and which of them the
/// viewer favourited. Every rule a viewer would notice lives here — a deleted
/// favourite must not survive as a dead card, and a channel in a gap must still
/// appear in the debug row.
void main() {
  final base = DateTime.utc(2026, 10, 8, 16, 0);

  TunarrChannel channel(String id, {String number = '1', String name = 'Channel', String? iconPath}) =>
      TunarrChannel(id: id, name: name, number: number, iconPath: iconPath);

  TunarrLineupSlot slot(
    String id,
    DateTime start,
    DateTime stop, {
    String type = 'content',
    String? title,
    String? externalId,
    String? programType,
    String? summary,
    int? year,
    String? contentRating,
  }) => TunarrLineupSlot(
    id: id,
    start: start.millisecondsSinceEpoch,
    stop: stop.millisecondsSinceEpoch,
    duration: stop.difference(start).inMilliseconds,
    type: type,
    program: title == null && externalId == null
        ? null
        : TunarrProgram(
            title: title,
            externalId: externalId,
            type: programType,
            summary: summary,
            year: year,
            contentRating: contentRating,
          ),
  );

  TunarrLineupChannel lineup(String id, List<TunarrLineupSlot> slots) =>
      TunarrLineupChannel(id: id, name: 'Channel', number: '1', slots: slots);

  group('galTvAiringAt', () {
    test('picks the slot covering now and carries its Plex ratingKey', () {
      final target = lineup('ch-1', [
        slot('a', base.subtract(const Duration(hours: 1)), base.add(const Duration(minutes: 30)),
            title: 'Earlier'),
        slot('b', base.add(const Duration(minutes: 30)), base.add(const Duration(hours: 2)),
            title: 'Iron Man', externalId: '466'),
      ]);

      final airing = galTvAiringAt(target, base.add(const Duration(minutes: 45)));

      expect(airing, isNotNull);
      expect(airing!.title, 'Iron Man');
      expect(airing.ratingKey, '466');
      expect(airing.start.toUtc(), base.add(const Duration(minutes: 30)));
    });

    test('a flex gap has nothing to show', () {
      final target = lineup('ch-1', [
        slot('gap', base, base.add(const Duration(minutes: 5)), type: 'flex'),
      ]);

      expect(galTvAiringAt(target, base.add(const Duration(minutes: 1))), isNull);
    });

    test('a slot with no Plex title is not airing anything the client can name', () {
      final target = lineup('ch-1', [
        slot('a', base, base.add(const Duration(minutes: 5))),
      ]);

      expect(galTvAiringAt(target, base.add(const Duration(minutes: 1))), isNull);
    });

    test('a channel with no schedule in the window is not airing', () {
      expect(galTvAiringAt(lineup('ch-1', const []), base), isNull);
    });
  });

  group('galTvNextAiring', () {
    test('returns the first playable slot still ahead of now', () {
      final target = lineup('ch-1', [
        slot('gap', base.subtract(const Duration(minutes: 2)), base.add(const Duration(minutes: 3)), type: 'flex'),
        slot('a', base.add(const Duration(minutes: 3)), base.add(const Duration(hours: 2)),
            title: 'Iron Man', externalId: '466', programType: 'movie'),
      ]);

      final next = galTvNextAiring(target, base);

      expect(next?.title, 'Iron Man');
      expect(next?.ratingKey, '466');
    });

    test('skips slots already over, and unnamed ones', () {
      final target = lineup('ch-1', [
        // Already finished: not the answer.
        slot('done', base.subtract(const Duration(hours: 2)), base.subtract(const Duration(hours: 1)), title: 'Earlier'),
        // Still ahead but carrying no program body: skipped, not returned as blank.
        slot('anon', base, base.add(const Duration(minutes: 1))),
        slot('b', base.add(const Duration(minutes: 1)), base.add(const Duration(hours: 1)), title: 'Greyhound'),
      ]);

      expect(galTvNextAiring(target, base)?.title, 'Greyhound');
    });

    test('a filler is not "the next movie/episode", so it is skipped', () {
      // The owner asked for the next *movie/episode*. A channel that runs 30 s
      // clips against a 150 s break would otherwise caption its card with the
      // next ad.
      final target = lineup('ch-1', [
        slot('ad', base, base.add(const Duration(seconds: 30)),
            title: 'Nemo dansaază', externalId: '5177', programType: 'other_video'),
        slot('film', base.add(const Duration(seconds: 30)), base.add(const Duration(hours: 2)),
            title: 'Knives Out', externalId: '900', programType: 'movie'),
      ]);

      expect(galTvNextAiring(target, base)?.title, 'Knives Out');
    });

    test('a programme with no library type is still shown', () {
      // Only an explicit `other_video` marks a filler; an unlabelled programme is
      // real content as far as the shelf can tell.
      final target = lineup('ch-1', [
        slot('a', base, base.add(const Duration(hours: 1)), title: 'The Target', externalId: '77'),
      ]);

      expect(galTvNextAiring(target, base)?.title, 'The Target');
    });

    test('an Other Videos clip the channel schedules itself is the next thing on', () {
      // `TEST FILLERS` is built from clips in an `Other Videos` library, so a
      // library-typed rule left its cards captioned with the bare channel name
      // while it was really about to play a clip (2026-10-09).
      final target = lineup('ch-1', [
        slot('gap', base, base.add(const Duration(minutes: 2)), type: 'flex'),
        slot('clip', base.add(const Duration(minutes: 2)), base.add(const Duration(minutes: 3)),
            title: 'Nemo danseaza', externalId: '5178', programType: 'other_video'),
      ]);

      expect(
        galTvNextAiring(target, base, ownOtherVideoIds: const {'clip'})?.title,
        'Nemo danseaza',
      );
      expect(
        galTvNextAiring(target, base)?.title,
        isNull,
        reason: 'without the channel’s own set the clip is still indistinguishable from an ad',
      );
    });

    test('nothing but gaps and fillers ahead means nothing to look at', () {
      final clips = lineup('ch-1', [
        slot('gap', base, base.add(const Duration(minutes: 5)), type: 'flex'),
        slot('ad', base.add(const Duration(minutes: 5)), base.add(const Duration(minutes: 6)),
            title: 'full', externalId: '5179', programType: 'other_video'),
      ]);

      expect(galTvNextAiring(clips, base), isNull);
    });
  });

  group('buildGalTvHomeShelves', () {
    List<String> hubIds(List<dynamic> hubs) => [for (final hub in hubs) hub.id as String];

    test('lists every channel, in the order given, whether or not it is airing', () {
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-1', number: '1', name: 'Movies'), channel('ch-2', number: '2', name: 'Comedy')],
        lineups: [
          lineup('ch-1', [
            slot('a', base.subtract(const Duration(minutes: 10)), base.add(const Duration(minutes: 50)),
                title: 'Civil War', externalId: '9'),
          ]),
          // ch-2 is in a gap: the debug row must still draw it.
          lineup('ch-2', [slot('gap', base, base.add(const Duration(minutes: 5)), type: 'flex')]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
      );

      expect(hubIds(shelves), [galTvAllChannelsHubId]);
      final items = shelves.single.items;
      expect(items.map((i) => i.id).toList(), [galTvShelfItemId('ch-1'), galTvShelfItemId('ch-2')]);
      expect(items[0].title, 'Civil War');
      expect(items[0].parentTitle, 'CH 1 · Movies');
      expect(items[1].title, 'Comedy', reason: 'a channel in a gap falls back to its own name');
    });

    test('the favourite shelf keeps favourite order and drops deleted channels', () {
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-1'), channel('ch-3')],
        lineups: const [],
        // 'ch-2' was deleted in Tunarr; 'ch-3' and 'ch-1' are still there.
        favoriteChannelIds: const {'ch-3', 'ch-2', 'ch-1'},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
      );

      // The favourites row leads: it is the one the viewer curated.
      expect(hubIds(shelves), [galTvFavoritesHubId, galTvAllChannelsHubId]);
      expect(shelves.first.items.map((i) => i.id).toList(), [
        galTvShelfItemId('ch-3'),
        galTvShelfItemId('ch-1'),
      ]);
    });

    test('a channel in a gap shows what is coming, and says so', () {
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-2', number: '2', name: 'COMEDY play', iconPath: '/images/uploads/logo.png')],
        lineups: [
          lineup('ch-2', [
            slot('gap', base, base.add(const Duration(minutes: 5)), type: 'flex'),
            slot('next', base.add(const Duration(minutes: 5)), base.add(const Duration(hours: 2)),
                title: 'Deadpool & Wolverine', externalId: '232', programType: 'movie'),
          ]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
        upcomingSubtitleFor: (c, startsAt) => 'CH ${c.number} · ${c.name} · at ${startsAt.minute}',
      );

      final card = shelves.single.items.single;
      expect(card.title, 'Deadpool & Wolverine', reason: 'the gap has nothing of its own to show');
      expect(card.thumbPath, '/library/metadata/232/art', reason: "the next programme's own artwork");
      expect(
        card.parentTitle,
        'CH 2 · COMEDY play · at 5',
        reason: 'the caption carries when it starts, so the card cannot read as "this is on now"',
      );
      expect(card.hasActiveProgress, isFalse, reason: 'nothing is playing, so there is no elapsed time');
    });

    test('a long ad break never becomes the card — what follows it does', () {
      // The owner's ask, 2026-10-09: the guide may show an "Ad Break" container,
      // but Home must keep showing the upcoming programme. Only breaks *longer*
      // than 30 minutes reach the client at all (Tunarr folds the rest away), so
      // this is the shape Home actually sees on a channel like TEST2.
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-4', number: '4', name: 'TEST2')],
        lineups: [
          lineup('ch-4', [
            slot('break', base, base.add(const Duration(minutes: 55)), type: 'flex'),
            slot('next', base.add(const Duration(minutes: 55)), base.add(const Duration(minutes: 115)),
                title: 'The Head', externalId: '3769', programType: 'episode'),
          ]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
        upcomingSubtitleFor: (c, startsAt) => 'CH ${c.number} · ${c.name} · at ${startsAt.minute}',
      );

      final card = shelves.single.items.single;
      expect(card.title, 'The Head');
      expect(card.thumbPath, '/library/metadata/3769/thumb', reason: "the episode's own still");
      expect(card.parentTitle, 'CH 4 · TEST2 · at 55');
      expect(card.hasActiveProgress, isFalse);
    });

    test('a gap with nothing ahead of it falls back to the channel itself', () {
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-2', number: '2', name: 'COMEDY play', iconPath: '/images/uploads/logo.png')],
        lineups: [
          lineup('ch-2', [slot('gap', base, base.add(const Duration(minutes: 5)), type: 'flex')]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
        upcomingSubtitleFor: (c, startsAt) => 'CH ${c.number} · ${c.name} · at ${startsAt.minute}',
        resolveLogoUrl: (iconPath) => iconPath == null ? null : 'https://gate.example$iconPath',
      );

      final card = shelves.single.items.single;
      expect(card.title, 'COMEDY play');
      expect(card.thumbPath, 'https://gate.example/images/uploads/logo.png');
      expect(card.parentTitle, 'CH 2 · COMEDY play', reason: 'there is nothing "next" to caption');
    });

    test('a playing card carries how far into the programme it is', () {
      // A 60-minute slot that started 10 minutes ago: the card draws the app's
      // own progress bar off these two — the same mechanism Continue Watching
      // uses — and only the *playing* card gets one.
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-1', number: '1', name: 'Movies')],
        lineups: [
          lineup('ch-1', [
            slot('now', base.subtract(const Duration(minutes: 10)), base.add(const Duration(minutes: 50)),
                title: 'Civil War', externalId: '9', programType: 'movie'),
          ]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
      );

      final card = shelves.single.items.single;
      expect(card.viewOffsetMs, const Duration(minutes: 10).inMilliseconds);
      expect(card.durationMs, const Duration(hours: 1).inMilliseconds);
      expect(card.hasActiveProgress, isTrue);
    });

    test('no favourites that still exist means no favourite shelf at all', () {
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-1')],
        lineups: const [],
        favoriteChannelIds: const {'deleted'},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number} · ${c.name}',
      );

      expect(hubIds(shelves), [galTvAllChannelsHubId]);
    });

    test('the programme backdrop is preferred and the channel logo is the fallback', () {
      final shelves = buildGalTvHomeShelves(
        channels: [channel('ch-1', iconPath: '/images/uploads/logo.png')],
        lineups: [
          lineup('ch-1', [
            slot('a', base, base.add(const Duration(minutes: 5)), title: 'Film', externalId: '42'),
          ]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
      );

      expect(shelves.single.items.single.thumbPath, '/library/metadata/42/art');

      final noAiring = buildGalTvHomeShelves(
        channels: [channel('ch-1', iconPath: '/images/uploads/logo.png')],
        lineups: const [],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
        resolveLogoUrl: (iconPath) => iconPath == null ? null : 'https://gate.example$iconPath',
      );

      expect(noAiring.single.items.single.thumbPath, 'https://gate.example/images/uploads/logo.png');
      expect(noAiring.single.items.single.kind, MediaKind.clip);
    });

    test('an airing episode asks for its own still, a movie for its backdrop', () {
      // Plex keeps a show's backdrop on the show, so an episode's `art` is the
      // image that does not resolve — the guide hit the same trap and falls back
      // to the episode's `thumb`, which is already 16:9.
      MediaHub shelfFor(String programType) => buildGalTvHomeShelves(
        channels: [channel('ch-1')],
        lineups: [
          lineup('ch-1', [
            slot('a', base, base.add(const Duration(minutes: 5)),
                title: 'The Grim Barbarity of Optics and Design', externalId: '3751', programType: programType),
          ]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
      ).single;

      expect(shelfFor('episode').items.single.thumbPath, '/library/metadata/3751/thumb');
      expect(shelfFor('movie').items.single.thumbPath, '/library/metadata/3751/art');
      expect(shelfFor('other_video').items.single.thumbPath, '/library/metadata/3751/art');
    });

    test('a card carries everything the TV preview paints', () {
      // The owner's report, 2026-10-09: focusing a GalTV card on the TV Home left
      // the spotlight blank, because the synthesized card had no `serverId` for the
      // preview to resolve an artwork client from and nothing for it to draw the
      // backdrop, wordmark, synopsis and metadata line with. The server id comes
      // from the app's Plex client — **not** from Tunarr, whose `mediaSourceId`
      // matches no client (verified on the TV 2026-10-10: the card previewed with
      // no image at all under the lineup's id).
      final shelf = buildGalTvHomeShelves(
        channels: [channel('ch-1')],
        lineups: [
          lineup('ch-1', [
            slot(
              'a',
              base,
              base.add(const Duration(hours: 2)),
              title: 'Iron Man',
              externalId: '466',
              programType: 'movie',
              summary: 'A billionaire builds a suit.',
              year: 2008,
              contentRating: 'PG-13',
            ),
          ]),
        ],
        favoriteChannelIds: const {},
        plexServerId: '2b4de25a5218f319e362965a18218950772171af',
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
      ).single;
      final card = shelf.items.single;

      expect(card.serverId, '2b4de25a5218f319e362965a18218950772171af');
      expect(card.artPath, '/library/metadata/466/art', reason: 'the hero backdrop the preview paints');
      expect(card.thumbPath, '/library/metadata/466/art');
      expect(card.clearLogoPath, '/library/metadata/466/clearLogo', reason: 'the wordmark, when Plex has one');
      expect(card.summary, 'A billionaire builds a suit.');
      expect(card.year, 2008);
      expect(card.contentRating, 'PG-13');
    });

    test('a filler never asks for a wordmark, and nothing named means no preview art', () {
      MediaHub shelfFor({required String? externalId, required String? programType}) => buildGalTvHomeShelves(
        channels: [channel('ch-1')],
        lineups: [
          lineup('ch-1', [
            slot('a', base, base.add(const Duration(minutes: 1)),
                title: 'Nemo danseaza', externalId: externalId, programType: programType),
          ]),
        ],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
      ).single;

      // An `Other Videos` library has no agent, so no `clearLogo` exists to ask
      // for — `ClearLogoImage` would only ever fall back to the title.
      expect(shelfFor(externalId: '5178', programType: 'other_video').items.single.clearLogoPath, isNull);
      expect(shelfFor(externalId: '5178', programType: 'other_video').items.single.artPath,
          '/library/metadata/5178/art');
      // A flex slot has no programme at all.
      final empty = buildGalTvHomeShelves(
        channels: [channel('ch-9', number: '9', name: 'Empty', iconPath: '/images/uploads/logo.png')],
        lineups: [lineup('ch-9', [slot('gap', base, base.add(const Duration(minutes: 5)), type: 'flex')])],
        favoriteChannelIds: const {},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
      ).single.items.single;
      expect(empty.summary, isNull);
      expect(empty.artPath, isNull);
      expect(empty.clearLogoPath, isNull);
    });

    test('a hydrated programme is the Plex item itself, so the preview reads like any shelf', () {
      // The owner's *"just use the exact same function it uses there"*: the card is
      // the Plex client's own mapping of the airing programme, so the metadata line
      // gets its `Movie` word, the score row, Plex's artwork and logo and the episode
      // numbering — nothing is reconstructed. Only GalTV's own four things are
      // overridden, and Plex's resume point is *cleared* on a card that is only
      // previewing what comes next.
      final hydrated = MediaItem(
        id: '466',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: 'Iron Man',
        summary: 'A billionaire builds a suit.',
        year: 2008,
        contentRating: 'PG-13',
        rating: 6.3,
        ratings: const [
          MediaRatingSource(source: 'rottenTomatoesCritic', value: 5.5),
          MediaRatingSource(source: 'rottenTomatoesAudience', value: 5.1),
          MediaRatingSource(source: 'imdb', value: 6.3),
          MediaRatingSource(source: 'tmdb', value: 6.1),
        ],
        serverId: '2b4de25a5218f319e362965a18218950772171af',
        artPath: '/library/metadata/466/art',
        clearLogoPath: '/library/metadata/466/clearLogo',
        durationMs: 7500000,
        viewOffsetMs: 900000,
      );
      MediaItem cardFor({required bool airing}) => buildGalTvHomeShelves(
        channels: [channel('ch-1')],
        lineups: [
          lineup('ch-1', [
            airing
                ? slot('a', base, base.add(const Duration(hours: 2)),
                    title: 'Iron Man', externalId: '466', programType: 'movie')
                // A gap: the card shows the programme that is still ahead.
                : slot('a', base.add(const Duration(minutes: 5)), base.add(const Duration(hours: 2)),
                    title: 'Iron Man', externalId: '466', programType: 'movie'),
          ]),
        ],
        favoriteChannelIds: const {},
        plexServerId: '2b4de25a5218f319e362965a18218950772171af',
        programmeItemsByChannel: {'ch-1': hydrated},
        now: base,
        allChannelsTitle: 'Live now',
        favoritesTitle: 'Favourite channels',
        subtitleFor: (c) => 'CH ${c.number}',
        upcomingSubtitleFor: (c, startsAt) => 'CH ${c.number} · Starts at',
      ).single.items.single;

      final airing = cardFor(airing: true);
      expect(airing.id, galTvShelfItemId('ch-1'), reason: 'the tap still routes to the channel');
      expect(airing.parentTitle, 'CH 1', reason: 'the channel is still the caption');
      expect(airing.kind, MediaKind.movie, reason: 'Plex’s kind, which prints the leading `Movie` word');
      expect(
        airing.ratings?.map((r) => r.source),
        ['rottenTomatoesCritic', 'rottenTomatoesAudience'],
        reason: 'only the tomato scores — what a Plex listing carries, and what every other shelf badges',
      );
      expect(airing.clearLogoPath, '/library/metadata/466/clearLogo');
      expect(airing.artPath, '/library/metadata/466/art');
      expect(airing.thumbPath, '/library/metadata/466/art');
      expect(airing.summary, 'A billionaire builds a suit.');
      expect(airing.viewOffsetMs, 0, reason: 'the channel’s elapsed time, not Plex’s resume point');
      expect(airing.durationMs, const Duration(hours: 2).inMilliseconds);

      // The same Plex item on a gap card: what comes next has no progress to show,
      // so Plex's 15-minute resume point must be cleared, not carried.
      final upcoming = cardFor(airing: false);
      expect(upcoming.viewOffsetMs, isNull, reason: 'a gap card previews; it does not resume');
      expect(upcoming.parentTitle, 'CH 1 · Starts at');
    });
  });

  test('a shelf card id round-trips to its channel id', () {
    expect(galTvShelfChannelId(galTvShelfItemId('4c3a112a-7da5-478e-adcf-bb63cae22644')),
        '4c3a112a-7da5-478e-adcf-bb63cae22644');
    expect(galTvShelfChannelId('some-plex-item'), isNull);
    expect(galTvShelfChannelId(galTvShelfItemIdPrefix), isNull);
  });
}
