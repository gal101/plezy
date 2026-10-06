import '../settings_service.dart';

/// The viewer's favourite GalTV channels, as a list of **Tunarr channel ids**.
///
/// The id is the only stable handle Tunarr offers: `GET /api/channels` answers
/// `{"id":"4c3a112a-7da5-478e-adcf-bb63cae22644","name":"Tom Cruise","number":1,…}`
/// and the id survives a rename, a renumber, a re-icon and a schedule rewrite —
/// so the list must never be keyed by any of those. Deleting a channel and
/// creating another *does* mint a new id, so that channel has to be favourited
/// again; that is unavoidable for any id scheme and it is the price of never
/// matching a favourite to the wrong channel.
///
/// The stored value lives in [SettingsService.galtvFavoriteChannelIds] and is
/// ordered by when each channel was favourited, which is the order the Home
/// shelf will render. The functions here are pure so the rules below can be
/// tested without prefs or a network.
class GalTvFavorites {
  const GalTvFavorites._();

  static List<String> read(SettingsService settings) => settings.read(SettingsService.galtvFavoriteChannelIds);

  static bool contains(Iterable<String> favorites, String channelId) => favorites.contains(channelId);

  /// [favorites] with [channelId] appended, or with its existing entry removed.
  ///
  /// Re-favouriting a channel that was unfavourited moves it to the end, which is
  /// also its place on the shelf; the list never grows duplicates.
  static List<String> toggled(Iterable<String> favorites, String channelId) {
    final next = favorites.toList();
    if (!next.remove(channelId)) next.add(channelId);
    return next;
  }

  /// The favourites that still exist in [knownChannelIds], in favourite order.
  ///
  /// Filtering — never pruning — is deliberate. A Tunarr that cannot be reached
  /// (an outage, a stale address, the gate hiccupping) answers with *no* channels,
  /// and a prune would then silently erase a list the viewer built by hand. A
  /// favourite whose channel is genuinely gone simply stops being shown, and comes
  /// back if the channel returns; only the viewer's own toggle (or [missing] being
  /// surfaced and acted on) writes to the stored list.
  static List<String> visible(Iterable<String> favorites, Set<String> knownChannelIds) => [
    for (final id in favorites)
      if (knownChannelIds.contains(id)) id,
  ];

  /// Favourites that [knownChannelIds] does not contain — for *telling* the
  /// viewer, never for deleting behind their back.
  ///
  /// Only meaningful when [knownChannelIds] came from a successful, complete
  /// channel load: pass nothing rather than an error's empty set.
  static List<String> missing(Iterable<String> favorites, Set<String> knownChannelIds) => [
    for (final id in favorites)
      if (!knownChannelIds.contains(id)) id,
  ];
}
