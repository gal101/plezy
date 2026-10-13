import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../models/tunarr/tunarr_channel.dart';
import '../../providers/tunarr_account_provider.dart';
import '../../services/galtv/galtv_favorites.dart';
import '../../services/galtv/galtv_favorites_sync.dart';
import '../../services/galtv/galtv_tuner.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/video_controls/widgets/channel_logo.dart';

/// The searchable GalTV favourites picker, reached from the Tunarr service
/// settings.
///
/// This is the **only** place a channel is favourited (the guide's long-press
/// was dropped): the whole list of channels the instance offers is fetched once
/// and filtered client-side, so searching costs no network.
///
/// Favourites are written through [GalTvFavorites.toggled] straight into
/// [SettingsService.galtvFavoriteChannelIds] — the same store the Home shelf
/// reads, keyed by channel id, so a rename here can never orphan an entry — and
/// then pushed to the account through [GalTvFavoritesSync], so a star here lands
/// on the viewer's other devices too.
class TunarrFavoritesScreen extends StatefulWidget {
  const TunarrFavoritesScreen({super.key, this.channelLoader});

  /// Test seam: replaces the account's `GET /api/channels` call. The default
  /// reads the bound [TunarrAccountProvider] client.
  final Future<List<TunarrChannel>> Function()? channelLoader;

  @override
  State<TunarrFavoritesScreen> createState() => _TunarrFavoritesScreenState();
}

class _TunarrFavoritesScreenState extends State<TunarrFavoritesScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'tunarr_favorites_search');

  List<TunarrChannel> _channels = const [];
  List<String> _favorites = const [];
  Map<String, String>? _logoHeaders;
  String? _baseUrl;
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _favorites = GalTvFavorites.read(SettingsService.instance);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final account = context.read<TunarrAccountProvider>();
    final loader = widget.channelLoader ?? account.client?.fetchChannels;
    if (loader == null) {
      setState(() {
        _loading = false;
        _channels = const [];
      });
      return;
    }

    try {
      final channels = GalTvTuner.sortedByNumber(await loader());
      // Reconcile with the account's list *before* showing anything: the stars in
      // this screen are the ones the Plex user owns, not the ones this device
      // happens to hold (and a first-time local list is pushed up, not wiped).
      // Null (an older gate, no network) leaves the cache exactly as it is.
      await account.favoritesSync?.pull();
      final plexToken = await account.resolvePlexToken();
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _favorites = GalTvFavorites.read(SettingsService.instance);
        _baseUrl = account.session?.baseUrl;
        _logoHeaders = plexToken == null || plexToken.isEmpty ? null : {'X-Plex-Token': plexToken};
        _loading = false;
      });
    } catch (error) {
      appLogger.w('Tunarr: channel list failed in the favourites picker', error: error);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = t.errors.unableToLoad(context: t.tunarr.title);
      });
    }
  }

  void _toggle(String channelId) {
    final next = GalTvFavorites.toggled(_favorites, channelId);
    setState(() => _favorites = next);
    unawaited(SettingsService.instance.write(SettingsService.galtvFavoriteChannelIds, next));
    // The write above is the star the viewer sees; telling the account is the
    // network half, and a failure there leaves the local value standing (the sync
    // remembers it and pushes again on the next pull).
    unawaited(_sync?.push(next) ?? Future<void>.value());
  }

  /// The account-backed half of the store, or null while disconnected — this
  /// screen then works exactly as it did before the sync existed.
  GalTvFavoritesSync? get _sync => context.read<TunarrAccountProvider>().favoritesSync;

  /// Number-or-title match, client-side over the already-fetched list.
  ///
  /// A number matches on prefix (typing `1` finds channel `12`), a name on a
  /// case-insensitive substring — the owner's *"search tv channels (by number or
  /// title)"*.
  List<TunarrChannel> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _channels;
    return [
      for (final channel in _channels)
        if (channel.number.toLowerCase().startsWith(query) || channel.name.toLowerCase().contains(query)) channel,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;

    return SettingsPage(
      title: Text(t.tunarr.favoriteChannels),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FocusableTextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t.tunarr.favoriteChannelsSearch,
              prefixIcon: const AppIcon(Symbols.search_rounded),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          SettingsGroup(children: [ListTile(title: Text(_error!))])
        else if (filtered.isEmpty)
          SettingsGroup(children: [ListTile(title: Text(t.tunarr.favoriteChannelsEmpty))])
        else
          SettingsGroup(
            children: [
              for (final channel in filtered)
                FocusableListTile(
                  key: ValueKey('tunarr-favorite-${channel.id}'),
                  leading: _channelLeading(channel),
                  title: Text('${channel.number} · ${channel.name}'),
                  trailing: AppIcon(
                    _favorites.contains(channel.id) ? Symbols.star_rounded : Symbols.star_border_rounded,
                    fill: _favorites.contains(channel.id) ? 1 : 0,
                    color: _favorites.contains(channel.id) ? theme.colorScheme.primary : null,
                  ),
                  onTap: () => _toggle(channel.id),
                ),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _channelLeading(TunarrChannel channel) {
    final logoUrl = resolveTunarrIconUrl(channel.iconPath, _baseUrl);
    if (logoUrl != null) {
      return ChannelLogo(url: logoUrl, size: 40, headers: _logoHeaders);
    }
    return CircleAvatar(radius: 20, child: Text(channel.number, style: const TextStyle(fontSize: 13)));
  }
}
