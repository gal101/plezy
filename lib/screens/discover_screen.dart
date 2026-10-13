import 'dart:async';
import '../media/ids.dart';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:plezy/widgets/app_icon.dart';
import '../widgets/server_activities_button.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../focus/focusable_action_bar.dart';
import '../focus/hub_vertical_navigation.dart';
import '../focus/locked_hub_controller.dart';
import '../focus/input_mode_tracker.dart';
import '../focus/key_event_utils.dart';

import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_server_client.dart';
import '../media/media_hub.dart';
import '../utils/media_image_helper.dart';
import '../utils/content_utils.dart';
import '../widgets/cycling_media_backdrop.dart';
import '../widgets/optimized_media_image.dart' show ClearLogoImage, blurArtwork;
import '../widgets/toolbar_scrim.dart';
import '../widgets/system_clock.dart';
import '../models/tunarr/tunarr_channel.dart';
import '../models/tunarr/tunarr_lineup.dart';
import '../providers/discover_provider.dart';
import '../providers/multi_server_provider.dart';
import '../providers/tunarr_account_provider.dart';
import '../providers/watch_state_store.dart';
import '../services/galtv/galtv_favorites.dart';
import '../services/galtv/galtv_home_shelves.dart';
import '../services/galtv/galtv_tuner.dart';
import '../services/plex_client.dart';
import '../widgets/hub_section.dart';
import '../widgets/app_menu.dart';
import '../widgets/clickable_cursor.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/profile_switching_overlay.dart';
import 'profile/profile_switch_screen.dart';
import 'profile/profile_teardown.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../profiles/profile_activation.dart';
import '../profiles/profile_avatar.dart';
import '../services/settings_service.dart';
import '../widgets/settings_builder.dart';
import '../widgets/fitting_title_text.dart';
import '../widgets/tv_browse_rail.dart';
import '../widgets/tv_spotlight_scaffold.dart';
import '../mixins/refreshable.dart';
import '../mixins/tab_visibility_aware.dart';
import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/formatters.dart';
import '../utils/hub_icons.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/video_player_navigation.dart';
import '../utils/layout_constants.dart';
import '../utils/platform_detector.dart';
import '../utils/tone_mapped_logo_image.dart';
import '../theme/mono_tokens.dart';
import 'libraries/content_state_builder.dart';
import 'libraries/state_messages.dart';
import 'main_screen.dart';
import '../navigation/settings_shortcut.dart';
import '../watch_together/watch_together.dart';
import '../providers/companion_remote_provider.dart';
import '../widgets/companion_remote/remote_session_dialog.dart';
import 'companion_remote/mobile_remote_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with Refreshable, ManualRefreshable, FullRefreshable, TabVisibilityAware, FocusableTab, WidgetsBindingObserver {
  static const Duration _heroAutoScrollDuration = Duration(seconds: 8);
  static const Duration _indicatorUpdateInterval = Duration(milliseconds: 200);

  /// Data + refresh policy live in [DiscoverProvider]; this state keeps only
  /// UI concerns (hero carousel, focus, spotlight). The proxy getters keep
  /// the build code reading naturally.
  late final DiscoverProvider _discover;
  int _seenLoadGeneration = 0;

  List<MediaItem> get _onDeck => _discover.onDeck;
  List<MediaHub> get _hubs => _discover.hubs;
  bool get _hasMoreContinueWatching => _discover.hasMoreContinueWatching;
  bool get _isLoading => _discover.isLoading;
  bool get _areHubsLoading => _discover.areHubsLoading;
  String? get _errorMessage => _discover.errorMessage == null ? null : t.errors.unableToLoad(context: t.discover.title);

  bool _switchingProfile = false;
  final PageController _heroController = PageController();
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<int> _heroIndex = ValueNotifier<int>(0);
  Timer? _autoScrollTimer;
  Timer? _indicatorTimer;
  final ValueNotifier<double> _indicatorProgress = ValueNotifier(0.0);
  bool _isAutoScrollPaused = false;
  bool _heroFocusPausedAutoScroll = false;
  final TvSpotlightController _spotlight = TvSpotlightController();
  bool _isTabVisible = true;

  bool _initialLoadComplete = false;
  bool _pendingTvBrowseRailFocus = false;

  /// Primary focus when the rail claim was armed; see [_railClaimAbandoned].
  FocusNode? _railClaimFocusOrigin;

  GlobalKey<HubSectionState>? _continueWatchingHubKey;
  final Map<String, GlobalKey<HubSectionState>> _hubKeysByIdentity = {};
  List<GlobalKey<HubSectionState>> _orderedHubKeys = const [];

  /// Locally-synthesized GalTV shelves (every channel, then the favourites),
  /// rendered ahead of Continue Watching. Empty whenever GalTV is off or no
  /// Tunarr session is bound, which is also what keeps Home from paying a doomed
  /// round trip for a profile that never signed in.
  List<MediaHub> _galtvShelfHubs = const [];
  final Map<String, GlobalKey<HubSectionState>> _galtvShelfHubKeys = {};

  /// The Tunarr account this screen subscribed to, so its (asynchronous) session
  /// bind can rebuild the shelves, and so [dispose] can unsubscribe.
  TunarrAccountProvider? _tunarrAccount;

  /// The favourites store's notifier, for the same reason: the picker is pushed
  /// *over* Home, so no tab event fires when a star is toggled. Owned and cached
  /// by [SettingsService] — remove the listener, never dispose it.
  late final ValueNotifier<List<String>> _favoritesListenable;

  GlobalKey<HubSectionState> _galtvShelfKey(String hubId) =>
      _galtvShelfHubKeys.putIfAbsent(hubId, GlobalKey<HubSectionState>.new);
  final _tvBrowseRailKey = GlobalKey<TvBrowseRailState>();
  final _hubFocusMemory = HubFocusMemory();

  late FocusNode _heroFocusNode;
  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _serverActivitiesButtonKey = GlobalKey<ServerActivitiesButtonState>();
  final _userMenuKey = GlobalKey<AppMenuButtonState<String>>();

  /// Backend-neutral hero client lookup. Returns the actual
  /// [MediaServerClient] for the item's server (Plex or Jellyfin) so
  /// [MediaImageHelper] uses the right transcoder for sized URLs.
  MediaServerClient? _getMediaClientForItem(MediaItem? item) {
    final serverId = item?.serverId;
    if (serverId == null) {
      return context.tryGetMediaClientForServer(null);
    }
    return context.tryGetMediaClientForServer(ServerId(serverId));
  }

  String _hubIdentity(MediaHub hub) => '${hub.serverId ?? ''}:${hub.identifier ?? hub.id}';

  /// Rebuild the per-hub focus keys, keyed by hub *identity* rather than
  /// list position so a row's focus memory follows it when the provider
  /// re-sorts hubs (library-order change). Existing keys are reused to avoid
  /// mass deep unmounts (ARM32 stack overflow during finalizeTree);
  /// duplicate identities get positional suffixes so two rows can never
  /// share a GlobalKey.
  void _updateHubKeys() {
    final occurrences = <String, int>{};
    final liveIdentities = <String>{};
    final ordered = <GlobalKey<HubSectionState>>[];
    for (final hub in _hubs) {
      var identity = _hubIdentity(hub);
      final occurrence = occurrences.update(identity, (n) => n + 1, ifAbsent: () => 0);
      if (occurrence > 0) identity = '$identity#$occurrence';
      liveIdentities.add(identity);
      ordered.add(_hubKeysByIdentity.putIfAbsent(identity, GlobalKey<HubSectionState>.new));
    }
    _hubKeysByIdentity.removeWhere((identity, _) => !liveIdentities.contains(identity));
    _orderedHubKeys = ordered;
    _continueWatchingHubKey ??= GlobalKey<HubSectionState>();
  }

  List<GlobalKey<HubSectionState>> get _allHubKeys {
    final keys = <GlobalKey<HubSectionState>>[];
    // Same order the rows are drawn in: Continue Watching, then the GalTV
    // shelves. The vertical-navigation indices are built from this list.
    if (_continueWatchingHubKey != null && _onDeck.isNotEmpty) {
      keys.add(_continueWatchingHubKey!);
    }
    keys.addAll([for (final hub in _galtvShelfHubs) _galtvShelfKey(hub.id)]);
    keys.addAll(_orderedHubKeys);
    return keys;
  }

  /// Rows drawn above the backend hubs: the GalTV shelves, plus Continue
  /// Watching when it has anything.
  int get _hubRowsAboveBackend => _galtvShelfHubs.length + (_onDeck.isNotEmpty ? 1 : 0);

  bool get _isHeroSectionVisible => _onDeck.isNotEmpty && context.settingsRead(SettingsService.showHeroSection);

  // Memoized on provider list identity (the provider always replaces _onDeck/
  // _hubs with fresh instances on change, never mutates in place) so unrelated
  // rebuilds hand TvBrowseRail the same hubs list and its didUpdateWidget
  // fast path — and the cached rail widget below — kick in.
  List<MediaHub>? _tvBrowseHubsCache;
  (List<MediaItem>, List<MediaHub>, bool, String, List<MediaHub>)? _tvBrowseHubsCacheKey;

  List<MediaHub> get _tvBrowseHubs {
    final key = (_onDeck, _hubs, _hasMoreContinueWatching, t.discover.continueWatching, _galtvShelfHubs);
    if (_tvBrowseHubsCache != null && key == _tvBrowseHubsCacheKey) return _tvBrowseHubsCache!;
    final hubs = <MediaHub>[];
    // Continue Watching first, then the GalTV shelves (favourites, then every
    // channel) — the owner's order: the rows you chose sit under the row the
    // server chose for you.
    if (_onDeck.isNotEmpty) {
      hubs.add(_continueWatchingHub);
    }
    hubs.addAll(_galtvShelfHubs);
    hubs.addAll(_hubs.where((hub) => hub.items.isNotEmpty));
    _tvBrowseHubsCache = hubs;
    _tvBrowseHubsCacheKey = key;
    return hubs;
  }

  /// The synthesized Continue Watching row, rendered ahead of the backend hubs
  /// on both the mobile list and the TV rail.
  MediaHub get _continueWatchingHub => MediaHub(
    id: 'continue_watching',
    title: t.discover.continueWatching,
    type: 'mixed',
    identifier: '_continue_watching_',
    size: _onDeck.length + (_hasMoreContinueWatching ? 1 : 0),
    more: _hasMoreContinueWatching,
    items: _onDeck,
  );

  /// The Tunarr account provider, or null when this screen is mounted outside a
  /// profile session — a bare screen in a test, or a tree with no Tunarr service
  /// at all. An optional Home shelf must never be the thing that breaks Home.
  TunarrAccountProvider? _tunarrAccountOrNull() {
    try {
      return context.read<TunarrAccountProvider>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// The **Plex item** behind each channel's airing (or next) programme, keyed by
  /// channel id.
  ///
  /// Full parity with every other Home shelf's preview: those cards come from a
  /// server payload, so the spotlight can show their score row (the lineup carries
  /// no score at all) and Plex's own artwork paths. One metadata read per channel
  /// with something to name, in parallel, on a shelf load — never per frame, and
  /// never a `native-playback` read, which is a *write* (`AGENT.md` §5).
  ///
  /// The programme picked here is the same one the shelf will draw: [galTvAiringAt]
  /// first, then [galTvNextAiring] — the exported helpers the builder itself calls,
  /// so the two can never disagree about which slot a card is about.
  ///
  /// A missing client, a channel with nothing named, or a failed fetch simply
  /// leaves that channel's card to the lineup's own fields.
  Future<Map<String, MediaItem>> _loadGalTvProgrammeItems({
    required PlexClient? plexClient,
    required List<TunarrLineupChannel> lineups,
    required Map<String, Set<String>> ownOtherVideoIdsByChannel,
    required DateTime now,
  }) async {
    if (plexClient == null) return const {};

    final ratingKeys = <String, String>{};
    for (final lineup in lineups) {
      final airing =
          galTvAiringAt(lineup, now) ??
          galTvNextAiring(lineup, now, ownOtherVideoIds: ownOtherVideoIdsByChannel[lineup.id] ?? const {});
      final ratingKey = airing?.ratingKey;
      if (ratingKey != null && ratingKey.isNotEmpty) ratingKeys[lineup.id] = ratingKey;
    }
    if (ratingKeys.isEmpty) return const {};

    final channelIds = ratingKeys.keys.toList();
    final items = await Future.wait(
      channelIds.map(
        (id) => plexClient.fetchItem(ratingKeys[id]!).then<MediaItem?>((item) => item, onError: (_, _) => null),
      ),
    );

    return <String, MediaItem>{
      for (var index = 0; index < channelIds.length; index++)
        if (items[index] != null) channelIds[index]: items[index]!,
    };
  }

  /// Rebuild the GalTV Home shelves: every channel, then the viewer's favourites.
  ///
  /// One `fetchChannels` plus **one** `fetchLineups` for the whole row — never a
  /// `native-playback` per channel, which would be N network round trips *and* N
  /// play-history writes (see `AGENT.md` §5). Both are cheap reads the guide
  /// already makes.
  ///
  /// Gated exactly as the tab is (`enableGaltv` + a bound client), and a failure
  /// clears the shelves rather than surfacing an error: Home's own content must
  /// not be held hostage by an optional shelf.
  Future<void> _loadGalTvShelves() async {
    final account = _tunarrAccountOrNull();
    final client = account?.client;
    if (!SettingsService.instance.read(SettingsService.enableGaltv) || client == null) {
      if (mounted && _galtvShelfHubs.isNotEmpty) setState(() => _galtvShelfHubs = const []);
      return;
    }

    // The favourites belong to the Plex account, not to this device: pull the
    // gate's copy before the shelves are built from the cache. Deliberately not
    // awaited — Home must never wait on a settings sync — and it does not need to
    // be: when the pull changes the cache, the favourites listenable fires
    // (`_onFavoritesChanged`) and reloads the shelves once with the fresh list.
    // A pull that changes nothing costs no write and no second load.
    unawaited(account?.favoritesSync?.pull());

    try {
      final now = DateTime.now();
      final results = await Future.wait<Object>([
        client.fetchChannels(),
        client.fetchLineups(
          from: now.subtract(const Duration(minutes: 30)),
          to: now.add(const Duration(hours: 12)),
        ),
      ]);
      if (!mounted) return;

      final channels = GalTvTuner.sortedByNumber(results[0] as List<TunarrChannel>);
      final lineups = results[1] as List<TunarrLineupChannel>;
      final baseUrl = account?.session?.baseUrl;
      // Which `Other Videos` programs each channel schedules *itself*: unlike the
      // raw library type, this is what tells a channel's own clips from the ads
      // Tunarr fills its breaks with (see `galTvProgramIsFiller`). Asked only of
      // the channels whose lineup carries such a program, so a deployment of films
      // and episodes pays nothing.
      final ownOtherVideoIds = await GalTvTuner(client: client).ownOtherVideoIdsByChannel(lineups);
      if (!mounted) return;

      // The app's own Plex server, for the cards' artwork client. Resolved through
      // the client (a `machineIdentifier`), never from Tunarr: the lineup's
      // `mediaSourceId` is Tunarr's own source UUID and matches no client, which
      // left every channel card previewing as a bare gradient. A setup with no
      // Plex client yet still gets its shelves — just without artwork or scores.
      PlexClient? plexClient;
      try {
        plexClient = context.getPlexClientWithFallback(null);
      } catch (_) {
        plexClient = null;
      }

      final programmeItems = await _loadGalTvProgrammeItems(
        plexClient: plexClient,
        lineups: lineups,
        ownOtherVideoIdsByChannel: ownOtherVideoIds,
        now: now,
      );
      if (!mounted) return;

      final hubs = buildGalTvHomeShelves(
        channels: channels,
        lineups: lineups,
        ownOtherVideoIdsByChannel: ownOtherVideoIds,
        plexServerId: plexClient?.serverId,
        programmeItemsByChannel: programmeItems,
        favoriteChannelIds: GalTvFavorites.read(SettingsService.instance).toSet(),
        now: now,
        allChannelsTitle: t.galtv.shelfAllChannels,
        favoritesTitle: t.galtv.shelfFavorites,
        subtitleFor: (channel) => t.galtv.channelLine(number: channel.number, name: channel.name),
        // A channel in a gap shows what is coming, so its caption carries the
        // channel *and* when that programme starts — otherwise the card reads as
        // "this is on now". The time is formatted here rather than in the shelf
        // builder, which stays free of widget-layer locators.
        upcomingSubtitleFor: (channel, startsAt) =>
            '${t.galtv.channelLine(number: channel.number, name: channel.name)} · '
            '${t.galtv.startsAt(time: MaterialLocalizations.of(context).formatTimeOfDay(
              TimeOfDay.fromDateTime(startsAt.toLocal()),
              alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
            ))}',
        resolveLogoUrl: (iconPath) => resolveTunarrIconUrl(iconPath, baseUrl),
      );
      setState(() => _galtvShelfHubs = hubs.where((hub) => hub.items.isNotEmpty).toList());
    } catch (error) {
      appLogger.w('GalTV: Home shelves could not be loaded', error: error);
      if (mounted && _galtvShelfHubs.isNotEmpty) setState(() => _galtvShelfHubs = const []);
    }
  }

  /// A Home shelf card opens the GalTV tab on its channel, at the live offset.
  void _openGalTvShelfItem(MediaItem item) {
    final channelId = galTvShelfChannelId(item.id);
    if (channelId == null) return;
    MainScreenFocusScope.openGalTvChannelOf(context, channelId);
  }

  /// Owns activation only for the GalTV shelves; the TV rail falls through to
  /// the normal item routing for every other hub.
  FutureOr<bool> _activateTvShelfItem(MediaHub hub, MediaItem item) {
    if (!_isGalTvShelfHub(hub)) return false;
    _openGalTvShelfItem(item);
    return true;
  }

  bool _isGalTvShelfHub(MediaHub hub) => _galtvShelfHubs.any((shelf) => shelf.id == hub.id);

  void _setSpotlightItem(MediaItem item) => _spotlight.select(item);

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void _focusTopActions() {
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final actionBar = _actionBarKey.currentState;
    if (actionBar != null) {
      actionBar.requestFocusOnFirst();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      _actionBarKey.currentState?.requestFocusOnFirst();
    });
  }

  void _focusTopBoundary() {
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    if (PlatformDetector.isTV()) {
      _focusTopActions();
    } else if (_isHeroSectionVisible) {
      _heroFocusNode.requestFocus();
    } else {
      _focusTopActions();
    }
    _scrollToTop();
  }

  void _focusContentFromAppBar() {
    if (PlatformDetector.isTV()) {
      _focusTvBrowseRailWhenReady(immediate: true);
      return;
    }

    if (_isHeroSectionVisible) {
      _heroFocusNode.requestFocus();
      return;
    }

    final keys = _allHubKeys;
    if (keys.isNotEmpty) {
      keys.first.currentState?.requestFocusFromMemory();
    }
  }

  void _focusTvBrowseRailWhenReady({bool immediate = false}) {
    if (!PlatformDetector.isTV()) return;
    if (!_isTabVisible || !(ModalRoute.of(context)?.isCurrent ?? false)) {
      _pendingTvBrowseRailFocus = false;
      return;
    }

    _pendingTvBrowseRailFocus = true;
    _railClaimFocusOrigin = FocusManager.instance.primaryFocus;
    if (immediate && _tvBrowseHubs.isNotEmpty) {
      final rail = _tvBrowseRailKey.currentState;
      if (rail != null) {
        _pendingTvBrowseRailFocus = false;
        rail.requestFocus();
        return;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_isTabVisible || !(ModalRoute.of(context)?.isCurrent ?? false)) {
        _pendingTvBrowseRailFocus = false;
        return;
      }
      if (_tvBrowseHubs.isEmpty) return;
      final rail = _tvBrowseRailKey.currentState;
      if (rail == null) return;
      _pendingTvBrowseRailFocus = false;
      rail.requestFocus();
    });
  }

  /// A rail-focus request stays armed while the rail has no hubs to focus
  /// (empty first load), so hubs landing later still receive it. It must not
  /// outlive the user's own navigation: hubs arriving minutes later would
  /// yank the remote off a sidebar item the user has since moved to.
  ///
  /// Where focus *sits* cannot tell those apart — MainScreen hands a tab over
  /// while focus is still on the sidebar item that selected it, and that
  /// request is as live as one made from a bare scope. What distinguishes a
  /// stale claim is that focus *moved* after the request was armed and now
  /// rests on a control off this screen. A bare scope — MainScreen's content
  /// scope before any child has focus — is "nowhere yet", not a destination.
  bool get _railClaimAbandoned {
    final node = FocusManager.instance.primaryFocus;
    if (identical(node, _railClaimFocusOrigin)) return false;
    final focusContext = node?.context;
    if (node == null || node is FocusScopeNode || focusContext == null) return false;
    return !identical(focusContext.findAncestorStateOfType<_DiscoverScreenState>(), this);
  }

  void _applyPendingTvBrowseRailFocus() {
    if (!_pendingTvBrowseRailFocus) return;
    if (_railClaimAbandoned) {
      _pendingTvBrowseRailFocus = false;
      return;
    }
    _focusTvBrowseRailWhenReady();
  }

  /// Handle vertical navigation between hubs
  /// Returns true if the navigation was handled
  bool _handleVerticalNavigation(int hubIndex, bool isUp) {
    final keys = _allHubKeys;
    return navigateVerticalHubRows(
      hubCount: keys.length,
      hubIndex: hubIndex,
      isUp: isUp,
      onTopBoundary: _focusTopBoundary,
      requestFocus: (targetIndex) {
        keys[targetIndex].currentState?.requestFocusFromMemory();
      },
    );
  }

  void _navigateToSidebar() {
    MainScreenFocusScope.focusSidebarOf(context);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _heroFocusNode = FocusNode(debugLabel: 'hero_section');
    _heroFocusNode.addListener(_onHeroFocusChanged);
    _discover = context.read<DiscoverProvider>();
    _seenLoadGeneration = _discover.loadGeneration;
    _discover.addListener(_onDiscoverChanged);
    _updateHubKeys();
    unawaited(_discover.load());
    // The Tunarr session is *loaded from the profile's store asynchronously*,
    // so at this point the provider is almost always still disconnected and
    // `client` is null. Subscribing is what makes the shelves appear at all:
    // without it the one early attempt would answer "no account" and nothing
    // would ever ask again.
    _tunarrAccount = _tunarrAccountOrNull();
    _tunarrAccount?.addListener(_onTunarrAccountChanged);
    // Shared, never-disposed notifier owned by the settings service.
    _favoritesListenable = SettingsService.instance.listenable(SettingsService.galtvFavoriteChannelIds);
    _favoritesListenable.addListener(_onFavoritesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadGalTvShelves());
    });
    _startAutoScroll();
  }

  /// A sign-in, a sign-out or the initial session bind all land here.
  void _onTunarrAccountChanged() {
    if (mounted) unawaited(_loadGalTvShelves());
  }

  /// A star toggled in Settings → Services → Tunarr → Favourite channels.
  ///
  /// That screen is *pushed over* Home, so leaving it fires no tab event and
  /// nothing else would ever notice; without this the favourite row would only
  /// appear after a tab switch. Reloading costs one cheap channel + lineup read,
  /// which is also what keeps "now playing" from going stale.
  void _onFavoritesChanged() {
    if (mounted) unawaited(_loadGalTvShelves());
  }

  /// Mirror provider changes into this state's UI concerns: rebuild, apply
  /// pending TV-rail focus, and keep the hero carousel index in sync — a
  /// fresh [DiscoverProvider.load] resets it, a background Continue Watching
  /// refresh only clamps it.
  /// Everything the build reads from the provider (list identities — the
  /// provider replaces lists on change — plus the scalar flags). Notifies
  /// that leave this unchanged (e.g. a watch-state-driven Continue Watching
  /// refresh that found nothing new) skip the setState so the whole screen —
  /// TV rail included — is not rebuilt for nothing.
  (List<MediaItem>, List<MediaHub>, bool, bool, bool, String?) get _renderSignature =>
      (_onDeck, _hubs, _hasMoreContinueWatching, _isLoading, _areHubsLoading, _discover.errorMessage);

  (List<MediaItem>, List<MediaHub>, bool, bool, bool, String?)? _seenRenderSignature;

  void _onDiscoverChanged() {
    if (!mounted) return;
    final generation = _discover.loadGeneration;
    final isNewLoad = generation != _seenLoadGeneration;
    _seenLoadGeneration = generation;
    final heroOutOfBounds = _heroIndex.value >= _onDeck.length;
    final signature = _renderSignature;
    final renderChanged = isNewLoad || heroOutOfBounds || signature != _seenRenderSignature;
    _seenRenderSignature = signature;

    if (renderChanged) {
      setState(() {
        if (isNewLoad || heroOutOfBounds) _heroIndex.value = 0;
        _updateHubKeys();
      });
    }
    _applyPendingTvBrowseRailFocus();

    if ((isNewLoad || heroOutOfBounds) && _heroController.hasClients && _onDeck.isNotEmpty) {
      _heroController.jumpToPage(0);
    }
    // Focus hero when fresh content lands, but only if no modal route is on top
    if (isNewLoad && !PlatformDetector.isTV() && _onDeck.isNotEmpty && (ModalRoute.of(context)?.isCurrent ?? false)) {
      _heroFocusNode.requestFocus();
    }

    // On initial load, focus content so the user doesn't start on the toolbar
    if (!_initialLoadComplete) {
      if (PlatformDetector.isTV() && (_onDeck.isNotEmpty || _hubs.isNotEmpty)) {
        _initialLoadComplete = true;
        _focusTvBrowseRailWhenReady();
      } else if (!PlatformDetector.isTV() && _onDeck.isNotEmpty) {
        _initialLoadComplete = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
          if (_heroFocusNode.canRequestFocus) {
            _heroFocusNode.requestFocus();
          }
        });
      }
    }
  }

  void _onHeroFocusChanged() {
    if (!PlatformDetector.isTV()) return;

    if (_heroFocusNode.hasFocus) {
      _heroFocusPausedAutoScroll = true;
      _autoScrollTimer?.cancel();
      _stopIndicatorProgress();
      return;
    }

    if (_heroFocusPausedAutoScroll) {
      _heroFocusPausedAutoScroll = false;
      if (_isTabVisible && !_isAutoScrollPaused) _startAutoScroll();
    }
  }

  /// Handle key events for the hero section.
  KeyEventResult _handleHeroKeyEvent(FocusNode node, KeyEvent event) {
    final backResult = handleBackKeyAction(event, _navigateToSidebar);
    if (backResult != KeyEventResult.ignored) return backResult;

    return dpadKeyHandler(
      onDown: () {
        final keys = _allHubKeys;
        if (keys.isNotEmpty) keys.first.currentState?.requestFocusFromMemory();
      },
      onUp: _focusTopActions,
      onLeft: () {
        if (_heroIndex.value > 0) {
          _heroController.previousPage(duration: tokens(context).slow, curve: Curves.easeInOut);
        } else {
          _navigateToSidebar();
        }
      },
      onRight: () {
        if (_heroIndex.value < _onDeck.length - 1) {
          _heroController.nextPage(duration: tokens(context).slow, curve: Curves.easeInOut);
        }
      },
      onSelect: () {
        final heroIndex = _heroIndex.value;
        if (_onDeck.isNotEmpty && heroIndex < _onDeck.length) {
          navigateToMediaItem(context, _onDeck[heroIndex], playDirectly: true);
        }
      },
    )(node, event);
  }

  @override
  void dispose() {
    _discover.removeListener(_onDiscoverChanged);
    _tunarrAccount?.removeListener(_onTunarrAccountChanged);
    _favoritesListenable.removeListener(_onFavoritesChanged);
    WidgetsBinding.instance.removeObserver(this);
    _autoScrollTimer?.cancel();
    _indicatorTimer?.cancel();
    _spotlight.dispose();
    _indicatorProgress.dispose();
    _heroIndex.dispose();
    _heroController.dispose();
    _scrollController.dispose();
    _heroFocusNode.removeListener(_onHeroFocusChanged);
    _heroFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Restart auto-scroll only if discover tab is visible
      if (_isTabVisible && !_isAutoScrollPaused) _startAutoScroll();
      // Stale hubs refetch on every resume — cheap timestamp check, and a
      // desktop window-focus gain after hours away should refresh too (#1646).
      final startedFullPass = _discover.refreshIfStale();
      // Refresh continue watching on mobile only
      // (on desktop, "resumed" fires on every window focus gain)
      if (!startedFullPass && (Platform.isIOS || Platform.isAndroid)) {
        unawaited(_discover.refreshContinueWatching());
      }
    } else if (state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      // Stop animations to prevent scroll state corruption while backgrounded
      _autoScrollTimer?.cancel();
      _stopIndicatorProgress();
    }
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    if (PlatformDetector.isTV()) return;
    if (_isAutoScrollPaused) return;

    _startIndicatorProgress();
    _autoScrollTimer = Timer.periodic(_heroAutoScrollDuration, (timer) {
      if (_onDeck.isEmpty || !_heroController.hasClients || _isAutoScrollPaused) {
        return;
      }

      // Validate current index is within bounds before calculating next page
      if (_heroIndex.value >= _onDeck.length) _heroIndex.value = 0;

      final nextPage = (_heroIndex.value + 1) % _onDeck.length;
      _heroController.animateToPage(nextPage, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
      // Wait for page transition to complete before resetting progress
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_isAutoScrollPaused) {
          _startIndicatorProgress();
        }
      });
    });
  }

  void _startIndicatorProgress() {
    if (!mounted) return;
    _indicatorTimer?.cancel();
    _indicatorProgress.value = 0.0;
    final totalSteps = _heroAutoScrollDuration.inMilliseconds ~/ _indicatorUpdateInterval.inMilliseconds;
    int step = 0;
    _indicatorTimer = Timer.periodic(_indicatorUpdateInterval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      step++;
      _indicatorProgress.value = (step / totalSteps).clamp(0.0, 1.0);
      if (step >= totalSteps) {
        timer.cancel();
      }
    });
  }

  void _stopIndicatorProgress() {
    _indicatorTimer?.cancel();
  }

  void _resetAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _startAutoScroll();
  }

  void _pauseAutoScroll() {
    setState(() {
      _isAutoScrollPaused = true;
    });
    _autoScrollTimer?.cancel();
    _stopIndicatorProgress();
  }

  void _resumeAutoScroll() {
    setState(() {
      _isAutoScrollPaused = false;
    });
    _startAutoScroll();
  }

  @override
  void onTabHidden() {
    _isTabVisible = false;
    _pendingTvBrowseRailFocus = false;
    _autoScrollTimer?.cancel();
    _stopIndicatorProgress();
  }

  @override
  void onTabShown() {
    _isTabVisible = true;
    _discover.refreshIfStale();
    // "Now playing" goes stale on its own, and a sign-in/sign-out or a
    // favourite toggled in Settings lands while another tab is up.
    unawaited(_loadGalTvShelves());
    if (!_isAutoScrollPaused) {
      _startAutoScroll();
    }
  }

  @override
  void focusActiveTabIfReady() {
    if (PlatformDetector.isTV()) {
      _focusTvBrowseRailWhenReady();
      return;
    }
    _focusTopBoundary();
  }

  // Helper method to calculate visible dot range (max 5 dots)
  ({int start, int end}) _getVisibleDotRange() {
    final totalDots = _onDeck.length;
    if (totalDots <= 5) {
      return (start: 0, end: totalDots - 1);
    }

    // Center the active dot when possible
    final center = _heroIndex.value;
    final int start = (center - 2).clamp(0, totalDots - 5);
    final int end = start + 4; // 5 dots total (0-4 inclusive)

    return (start: start, end: end);
  }

  // Helper method to determine dot size based on position
  double _getDotSize(int dotIndex, int start, int end) {
    final totalDots = _onDeck.length;

    // If we have 5 or fewer dots, all are full size (8px)
    if (totalDots <= 5) {
      return 8.0;
    }

    // First and last visible dots are smaller if there are more items beyond them
    final isFirstVisible = dotIndex == start && start > 0;
    final isLastVisible = dotIndex == end && end < totalDots - 1;

    if (isFirstVisible || isLastVisible) {
      return 5.0; // Smaller edge dots
    }

    return 8.0; // Normal size
  }

  @override
  void manualRefresh() => unawaited(_refreshFromToolbar());

  Future<void> _refreshFromToolbar() async {
    final outcome = await _discover.refreshNow();
    if (!mounted) return;
    switch (outcome) {
      case DiscoverRefreshOutcome.failed:
        showErrorSnackBar(context, t.errors.unableToLoad(context: t.discover.title));
      case DiscoverRefreshOutcome.degraded:
        appLogger.w('Discover refresh completed with partial server failures');
      case DiscoverRefreshOutcome.cancelled:
      case DiscoverRefreshOutcome.refreshed:
        break;
    }
  }

  // Public method to refresh content (for normal navigation)
  @override
  void refresh() {
    // A stale-resume refresh must also refetch the home hubs; otherwise new
    // server-side media never appears until a restart (#1646). When fresh,
    // only Continue Watching refetches — one on-deck call, zero hub calls.
    if (_discover.refreshIfStale()) return;
    unawaited(_discover.refreshContinueWatching());
  }

  // Public method to fully reload all content (for profile switches)
  @override
  void fullRefresh() {
    unawaited(_discover.load());
  }

  @override
  void primeRefresh() {
    // `initState` already fired `load()`. On cold start that pass is still
    // running when the online-entry hook primes the tab, and asking again only
    // queues an identical trailing pass — the whole home fan-out twice (#1784).
    // When nothing is in flight (reconnect-from-offline, or a first pass that
    // gave up because no server was online yet) a real refresh is still owed.
    if (_discover.isLoadInFlight) return;
    fullRefresh();
  }

  /// Whether the loaded hubs span more than one connected server.
  bool _hubsSpanMultipleServers() {
    final serverIds = _hubs.where((hub) => hub.serverId != null).map((hub) => hub.serverId).toSet();
    return serverIds.length > 1;
  }

  Future<void> _handleLogout() async {
    final confirm = await showConfirmDialog(
      context,
      title: t.common.logout,
      message: t.messages.logoutConfirm,
      confirmText: t.common.logout,
      isDestructive: true,
    );

    if (confirm && mounted) {
      await logoutAllProfiles(context);
    }
  }

  void _handleSwitchProfile(BuildContext context) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (context) => const ProfileSwitchScreen()));
  }

  void _handleOpenSettings(BuildContext context) {
    final mainScope = MainScreenFocusScope.of(context, listen: false);
    if (mainScope != null) {
      mainScope.openSettings?.call();
      return;
    }

    Navigator.push(context, buildSettingsRoute());
  }

  /// Build the [FocusableAction] wrapping the user menu.
  /// Pulls live state from [ActiveProfileProvider]; the menu reuses
  /// [_userMenuItems] for the menu contents so d-pad and tap paths
  /// stay in sync.
  FocusableAction _buildUserMenuAction(BuildContext context) {
    final activeProvider = context.watch<ActiveProfileProvider>();
    final active = activeProvider.active;
    final profiles = activeProvider.profiles;

    return FocusableAction(
      onPressed: _switchingProfile ? null : () => _userMenuKey.currentState?.showButtonMenu(focusFirstItem: true),
      child: AppMenuButton<String>(
        key: _userMenuKey,
        enabled: !_switchingProfile,
        icon: active != null
            ? ProfileAvatar(profile: active, size: 32, avatarUrl: activeProvider.avatarUrlFor(active.id))
            : const AppIcon(Symbols.account_circle_rounded, fill: 1, size: 32, color: Colors.white),
        tooltip: t.profiles.sectionTitle,
        adaptiveSheet: true,
        anchorAlignment: AppMenuAnchorAlignment.end,
        onSelected: (value) => unawaited(_handleUserMenuAction(context, value)),
        entriesBuilder: (context) =>
            _userMenuItems(context, activeProfile: active, profiles: profiles, activeProvider: activeProvider),
      ),
    );
  }

  List<AppMenuEntry<String>> _userMenuItems(
    BuildContext context, {
    required Profile? activeProfile,
    required List<Profile> profiles,
    required ActiveProfileProvider activeProvider,
  }) {
    final theme = Theme.of(context);
    final switchable = profiles.where((p) => p.id != activeProfile?.id).toList();

    return [
      for (final p in switchable)
        AppMenuItem<String>(
          value: 'profile:${p.id}',
          leading: ProfileAvatar(profile: p, size: 24, avatarUrl: activeProvider.avatarUrlFor(p.id)),
          label: p.displayName,
          trailing: p.isPinProtected
              ? AppIcon(Symbols.lock_rounded, fill: 1, size: 14, color: theme.colorScheme.onSurfaceVariant)
              : null,
        ),
      if (switchable.isNotEmpty) const AppMenuDivider(),
      AppMenuItem<String>(value: 'manage_profiles', icon: Symbols.group_rounded, label: t.profiles.sectionTitle),
      AppMenuItem<String>(value: 'settings', icon: Symbols.settings_rounded, label: t.common.settings),
      AppMenuItem<String>(value: 'logout', icon: Symbols.logout_rounded, label: t.common.logout),
    ];
  }

  Future<void> _handleUserMenuAction(BuildContext context, String value) async {
    if (_switchingProfile) return;
    if (value == 'logout') {
      unawaited(_handleLogout());
      return;
    }
    if (value == 'manage_profiles') {
      _handleSwitchProfile(context);
      return;
    }
    if (value == 'settings') {
      _handleOpenSettings(context);
      return;
    }
    if (value.startsWith('profile:')) {
      final id = value.substring('profile:'.length);
      final active = context.read<ActiveProfileProvider>();
      final target = active.profiles.where((p) => p.id == id).firstOrNull;
      if (target == null) return;
      await _switchProfileFromMenu(target);
    }
  }

  Future<void> _switchProfileFromMenu(Profile profile) async {
    if (_switchingProfile) return;
    setState(() => _switchingProfile = true);
    try {
      await switchProfileFromUi(context, profile);
    } finally {
      if (mounted) {
        setState(() => _switchingProfile = false);
      }
    }
  }

  Widget _buildOverlaidAppBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor = colorScheme.onSurface;
    return ToolbarScrim(
      child: Row(
        children: [
          if (!PlatformDetector.isTV())
            Text(
              t.discover.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(color: foregroundColor, fontWeight: .bold),
            ),
          const Spacer(),
          // TV only: a fullscreen leanback app hides the system clock, while a
          // phone status bar and a desktop menu bar already show one.
          if (PlatformDetector.isTV()) ...[
            SystemClock(
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: foregroundColor, fontWeight: .w500),
            ),
            const SizedBox(width: 12),
          ],
          Consumer2<WatchTogetherProvider, CompanionRemoteProvider>(
            builder: (context, watchTogether, companionRemote, _) {
              final isDesktop = PlatformDetector.shouldActAsRemoteHost(context);
              void openWatchTogether() =>
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const WatchTogetherScreen()));
              void openCompanionRemote() {
                if (isDesktop) {
                  RemoteSessionDialog.show(context);
                } else {
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const MobileRemoteScreen()));
                }
              }

              return FocusableActionBar(
                key: _actionBarKey,
                onNavigateLeft: _navigateToSidebar,
                onNavigateDown: _focusContentFromAppBar,
                actions: [
                  FocusableAction(icon: Symbols.refresh_rounded, iconColor: foregroundColor, onPressed: manualRefresh),
                  // Watch Together
                  FocusableAction(
                    onPressed: openWatchTogether,
                    child: Stack(
                      children: [
                        IconButton(
                          icon: AppIcon(
                            Symbols.group_rounded,
                            fill: watchTogether.isInSession ? 1 : 0,
                            color: watchTogether.isInSession ? colorScheme.primary : foregroundColor,
                          ),
                          onPressed: openWatchTogether,
                          tooltip: t.watchTogether.title,
                        ),
                        if (watchTogether.isInSession && watchTogether.participantCount > 1)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: colorScheme.primary,
                                borderRadius: const BorderRadius.all(Radius.circular(8)),
                              ),
                              child: Text(
                                '${watchTogether.participantCount}',
                                style: TextStyle(color: colorScheme.onPrimary, fontSize: 10, fontWeight: .bold),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Companion Remote
                  FocusableAction(
                    onPressed: openCompanionRemote,
                    child: Stack(
                      children: [
                        IconButton(
                          icon: AppIcon(
                            Symbols.phone_android_rounded,
                            fill: companionRemote.isConnected ? 1 : 0,
                            color: companionRemote.isConnected ? colorScheme.primary : foregroundColor,
                          ),
                          onPressed: openCompanionRemote,
                          tooltip: t.companionRemote.title,
                        ),
                        if (companionRemote.isConnected)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.fromBorderSide(BorderSide(color: foregroundColor, width: 1)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Server Tasks — Plex-only (`/activities` API has no
                  // Jellyfin equivalent), hide the button entirely on
                  // Jellyfin-only profiles so the chrome doesn't show
                  // a permanently empty popover.
                  if (PlatformDetector.isDesktop(context) &&
                      context.select<MultiServerProvider, bool>((p) => p.hasOnlinePlexServers))
                    FocusableAction(
                      onPressed: () => _serverActivitiesButtonKey.currentState?.togglePanel(),
                      child: ServerActivitiesButton(key: _serverActivitiesButtonKey),
                    ),
                  // User menu — profiles + sign out
                  _buildUserMenuAction(context),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsBuilder(
      prefs: const [
        SettingsService.showServerNameOnHubs,
        SettingsService.showHeroSection,
        SettingsService.hideSpoilers,
        SettingsService.libraryDensity,
        SettingsService.episodePosterMode,
      ],
      builder: (context) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final svc = SettingsService.instance;
    final showHeroSection = svc.read(SettingsService.showHeroSection);

    if (PlatformDetector.isTV()) {
      return _buildTvContent(context);
    }

    final showServerNameOnHubs = svc.read(SettingsService.showServerNameOnHubs);
    final hubsSpanMultipleServers = _hubsSpanMultipleServers();

    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final theme = Theme.of(context);
    final continueWatchingHub = _onDeck.isEmpty ? null : _continueWatchingHub;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // Hero Section (Continue Watching) - at top of screen
              Builder(
                builder: (context) {
                  if (_onDeck.isNotEmpty && showHeroSection) {
                    return _buildHeroSection();
                  }
                  // Add top padding when hero is not shown
                  return SliverToBoxAdapter(
                    child: SizedBox(height: kToolbarHeight + MediaQuery.paddingOf(context).top + 16),
                  );
                },
              ),
              if (_isLoading) LoadingIndicatorBox.sliver,
              if (_errorMessage != null) SliverErrorState(message: _errorMessage!, onRetry: _discover.load),
              if (!_isLoading && _errorMessage == null) ...[
                if (continueWatchingHub != null)
                  SliverToBoxAdapter(
                    child: HubSection(
                      key: _continueWatchingHubKey,
                      hub: continueWatchingHub,
                      focusMemory: _hubFocusMemory,
                      icon: hubIconFor(continueWatchingHub),
                      onRefresh: _discover.updateItem,
                      onRemoveFromContinueWatching: _discover.refreshContinueWatching,
                      isInContinueWatching: true,
                      loadMoreItems: _discover.loadAllContinueWatching,
                      onVerticalNavigation: (isUp) => _handleVerticalNavigation(0, isUp),
                      onNavigateUp: _focusTopBoundary,
                      onNavigateToSidebar: _navigateToSidebar,
                    ),
                  ),

                // The GalTV shelves follow Continue Watching: favourites first
                // (they are the rows the viewer chose), then every channel.
                for (int j = 0; j < _galtvShelfHubs.length; j++)
                  SliverToBoxAdapter(
                    child: HubSection(
                      key: _galtvShelfKey(_galtvShelfHubs[j].id),
                      hub: _galtvShelfHubs[j],
                      focusMemory: _hubFocusMemory,
                      icon: hubIconFor(_galtvShelfHubs[j]),
                      onItemTap: _openGalTvShelfItem,
                      onVerticalNavigation: (isUp) =>
                          _handleVerticalNavigation((_onDeck.isNotEmpty ? 1 : 0) + j, isUp),
                      onNavigateUp: (!_onDeck.isNotEmpty && j == 0) ? _focusTopBoundary : null,
                      onNavigateToSidebar: _navigateToSidebar,
                    ),
                  ),

                // Recommendation Hubs (Trending, Top in Genre, etc.)
                for (int i = 0; i < _hubs.length; i++)
                  SliverToBoxAdapter(
                    child: HubSection(
                      key: i < _orderedHubKeys.length ? _orderedHubKeys[i] : null,
                      hub: _hubs[i],
                      focusMemory: _hubFocusMemory,
                      icon: hubIconFor(_hubs[i]),
                      showServerName: showServerNameOnHubs || hubsSpanMultipleServers,
                      onRefresh: _discover.updateItem,
                      onVerticalNavigation: (isUp) => _handleVerticalNavigation(_hubRowsAboveBackend + i, isUp),
                      onNavigateUp: (i == 0 && _hubRowsAboveBackend == 0) ? _focusTopBoundary : null,
                      onNavigateToSidebar: _navigateToSidebar,
                    ),
                  ),

                // Show loading skeleton for hubs while they're loading
                if (_areHubsLoading && _hubs.isEmpty)
                  for (int i = 0; i < 3; i++)
                    SliverToBoxAdapter(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: .start,
                          children: [
                            Container(
                              width: 200,
                              height: 24,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: const BorderRadius.all(Radius.circular(4)),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 200,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: 5,
                                itemBuilder: (context, index) {
                                  return Container(
                                    margin: const EdgeInsets.only(right: 12),
                                    width: 140,
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                if (_onDeck.isEmpty && _hubs.isEmpty && !_areHubsLoading)
                  SliverEmptyState(
                    message: t.discover.noContentAvailable,
                    subtitle: t.discover.addMediaToLibraries,
                    icon: Symbols.movie_rounded,
                  ),

                SliverToBoxAdapter(child: SizedBox(height: 24 + bottomPadding)),
              ],
            ],
          ),
          // Overlaid app bar — excluded from default focus traversal so that
          // initial/tab-switch focus lands on content (hero/hubs), not the toolbar.
          // Toolbar buttons are still reachable via explicit UP from hero section.
          Positioned(top: 0, left: 0, right: 0, child: ExcludeFocusTraversal(child: _buildOverlaidAppBar())),
          if (_switchingProfile) const ProfileSwitchingOverlay(),
        ],
      ),
    );
  }

  // Cached so unrelated _buildTvContent rebuilds (loading flags, spotlight
  // geometry) hand Element.updateChild the identical widget instance and the
  // whole rail subtree is skipped. Rebuilt only when its actual inputs change.
  TvBrowseRail? _tvBrowseRailWidget;
  (List<MediaHub>, bool)? _tvBrowseRailWidgetKey;

  Widget _cachedTvBrowseRail(List<MediaHub> browseHubs, {required bool showServerName}) {
    final key = (browseHubs, showServerName);
    if (_tvBrowseRailWidget != null && key == _tvBrowseRailWidgetKey) return _tvBrowseRailWidget!;
    _tvBrowseRailWidgetKey = key;
    return _tvBrowseRailWidget = TvBrowseRail(
      key: _tvBrowseRailKey,
      hubs: browseHubs,
      initialHubId: 'continue_watching',
      focusMemory: _hubFocusMemory,
      showServerName: showServerName,
      iconForHub: (hub, _) => hubIconFor(hub),
      onFocusedItemChanged: _setSpotlightItem,
      onRefresh: _discover.updateItem,
      onRemoveFromContinueWatching: _discover.refreshContinueWatching,
      isContinueWatchingHub: (hub) => hub.isContinueWatchingHub,
      usesContinueWatchingAction: (hub) => hub.usesContinueWatchingAction,
      // GalTV shelf cards open the GalTV tab on their channel; every other hub
      // keeps the rail's default item activation.
      onActivateItem: _activateTvShelfItem,
      // Every other hub pages from its server in View All, as on phones; handing
      // it the preview items only showed that preview again.
      loadMoreItems: (hub) => hub.id == 'continue_watching' ? _discover.loadAllContinueWatching : null,
      onNavigateUp: _focusTopActions,
      onNavigateToSidebar: _navigateToSidebar,
      tallPosterScale: TvBrowseRailLayout.compactTallPosterScale,
    );
  }

  Widget _buildTvContent(BuildContext context) {
    final svc = SettingsService.instance;
    final hideSpoilers = svc.read(SettingsService.hideSpoilers);
    final showServerNameOnHubs = svc.read(SettingsService.showServerNameOnHubs);
    final hubsSpanMultipleServers = _hubsSpanMultipleServers();
    final browseHubs = _tvBrowseHubs;

    return TvSpotlightScaffold(
      hubs: browseHubs,
      spotlightListenable: _spotlight,
      resolveSpotlight: () => _spotlight.resolve(browseHubs),
      resolveClient: _getMediaClientForItem,
      hideSpoilers: hideSpoilers,
      foreground: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          if (_isLoading || (_areHubsLoading && browseHubs.isEmpty)) const Center(child: CircularProgressIndicator()),
          if (_errorMessage != null)
            ErrorStateWidget(
              message: _errorMessage!,
              icon: Symbols.error_outline_rounded,
              onRetry: _discover.load,
              actionAutofocus: true,
              actionUseBackgroundFocus: true,
            ),
          if (!_isLoading && _errorMessage == null && browseHubs.isEmpty && !_areHubsLoading)
            EmptyStateWidget(
              message: t.discover.noContentAvailable,
              subtitle: t.discover.addMediaToLibraries,
              icon: Symbols.movie_rounded,
            ),
          if (browseHubs.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _cachedTvBrowseRail(browseHubs, showServerName: showServerNameOnHubs || hubsSpanMultipleServers),
            ),
          TvToolbarOverlay(child: _buildOverlaidAppBar()),
          if (_switchingProfile) const ProfileSwitchingOverlay(),
        ],
      ),
    );
  }

  Widget _buildHeroSection() {
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    final useSideNav = PlatformDetector.shouldUseSideNavigation(context);
    final isTv = PlatformDetector.isTV();
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    // Mobile keeps its fixed hero, except that a landscape phone is shorter
    // than the hero itself; fill the viewport there and let the item compact.
    final heroHeight = isTv
        ? viewportHeight * 0.82
        : useSideNav
        ? viewportHeight * 0.75
        : isLandscape
        ? math.min(500 + statusBarHeight, viewportHeight)
        : 500 + statusBarHeight;
    return SliverToBoxAdapter(
      child: Focus(
        focusNode: _heroFocusNode,
        onKeyEvent: _handleHeroKeyEvent,
        child: SizedBox(
          height: heroHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              PageView.builder(
                controller: _heroController,
                itemCount: _onDeck.length,
                onPageChanged: (index) {
                  if (index >= 0 && index < _onDeck.length) {
                    _heroIndex.value = index;
                    _resetAutoScrollTimer();
                  }
                },
                itemBuilder: (context, index) {
                  return _buildHeroItem(_onDeck[index], heroHeight);
                },
              ),
              // Page indicators with animated progress and pause/play button.
              // Hidden on TV only (issue #600: pointer-only control unreachable
              // via d-pad) — never gated on transient input mode, which back-key
              // events, BT keyboards, and gamepads can flip on phones/desktop.
              if (!isTv)
                Positioned(
                  bottom: 16,
                  left: -26,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: .center,
                    children: [
                      // Pause/Play button
                      ClickableCursor(
                        child: GestureDetector(
                          onTap: () {
                            if (_isAutoScrollPaused) {
                              _resumeAutoScroll();
                            } else {
                              _pauseAutoScroll();
                            }
                          },
                          child: AppIcon(
                            _isAutoScrollPaused ? Symbols.play_arrow_rounded : Symbols.pause_rounded,
                            fill: 1,
                            color: Theme.of(context).colorScheme.onSurface,
                            size: 18,
                            semanticLabel: _isAutoScrollPaused
                                ? t.accessibility.autoScrollPlay
                                : t.accessibility.autoScrollPause,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ValueListenableBuilder<int>(
                        valueListenable: _heroIndex,
                        builder: (context, heroIndex, _) {
                          final range = _getVisibleDotRange();
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: List.generate(range.end - range.start + 1, (i) {
                              final index = range.start + i;
                              final isActive = heroIndex == index;
                              final dotSize = _getDotSize(index, range.start, range.end);

                              return isActive
                                  ? ValueListenableBuilder<double>(
                                      valueListenable: _indicatorProgress,
                                      builder: (context, progress, child) {
                                        final maxWidth = dotSize * 3;
                                        final fillWidth = dotSize + ((maxWidth - dotSize) * progress);
                                        final onSurface = Theme.of(context).colorScheme.onSurface;
                                        return Container(
                                          margin: const EdgeInsets.symmetric(horizontal: 4),
                                          width: maxWidth,
                                          height: dotSize,
                                          decoration: BoxDecoration(
                                            color: onSurface.withValues(alpha: 0.4),
                                            borderRadius: BorderRadius.circular(dotSize / 2),
                                          ),
                                          child: Align(
                                            alignment: .centerLeft,
                                            child: Container(
                                              width: fillWidth,
                                              height: dotSize,
                                              decoration: BoxDecoration(
                                                color: onSurface,
                                                borderRadius: BorderRadius.circular(dotSize / 2),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    )
                                  : AnimatedContainer(
                                      duration: tokens(context).slow,
                                      curve: Curves.easeInOut,
                                      margin: const EdgeInsets.symmetric(horizontal: 4),
                                      width: dotSize,
                                      height: dotSize,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(dotSize / 2),
                                      ),
                                    );
                            }),
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroItem(MediaItem heroItem, double heroHeight) {
    final heroClient = _getMediaClientForItem(heroItem);
    final isEpisode = heroItem.isEpisode;
    final showName = heroItem.grandparentTitle ?? heroItem.displayTitle;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final heroAspectRatio = screenWidth / heroHeight;
    final heroArtPaths = heroItem.heroArtCandidates(containerAspectRatio: heroAspectRatio);
    final isLargeScreen = ScreenBreakpoints.isWideTabletOrLarger(screenWidth);
    final isTv = PlatformDetector.isTV();
    final alignLeft = isTv || isLargeScreen;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // A landscape phone hands the hero the whole ~400dp viewport; the usual
    // logo and bottom offset would push the content up into the top bar.
    final compact = !isTv && heroHeight < 450;
    final heroLogoWidth = isTv ? TvLayoutConstants.heroLogoWidth : 400.0;
    final heroLogoHeight = isTv
        ? TvLayoutConstants.heroLogoHeight
        : compact
        ? 80.0
        : 120.0;
    final heroTitleStyle = theme.textTheme.displaySmall?.copyWith(
      color: colorScheme.onSurface,
      fontWeight: .bold,
      fontSize: isTv ? 52 : null,
      shadows: [Shadow(color: colorScheme.surface.withValues(alpha: 0.8), blurRadius: 8)],
    );

    final contentTypeLabel = heroItem.isMovie ? t.discover.movie : t.discover.tvShow;

    final hideSpoilers = SettingsService.instance.read(SettingsService.hideSpoilers);
    final shouldHideSpoiler = hideSpoilers && heroItem.shouldHideSpoiler;

    final heroLabel = isEpisode ? "${heroItem.grandparentTitle}, ${heroItem.title}" : heroItem.title;

    return Semantics(
      label: heroLabel,
      button: true,
      hint: t.accessibility.tapToPlay,
      child: ClickableCursor(
        child: GestureDetector(
          onTap: () {
            appLogger.d('Activating hero item: ${heroItem.title}');
            navigateToMediaItem(context, heroItem, playDirectly: true);
          },
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              // Background Image with fade/zoom animation and parallax
              if (heroArtPaths.isNotEmpty)
                ClipRect(
                  child: AnimatedBuilder(
                    animation: _scrollController,
                    builder: (context, child) {
                      final scrollOffset = _scrollController.hasClients ? _scrollController.offset : 0.0;
                      return Transform.translate(offset: Offset(0, scrollOffset * 0.3), child: child);
                    },
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: const Duration(milliseconds: 800),
                      curve: Curves.easeOut,
                      builder: (context, value, child) {
                        return Transform.scale(
                          scale: 1.0 + (0.1 * (1 - value)),
                          child: Opacity(opacity: value, child: child),
                        );
                      },
                      child: Builder(
                        builder: (context) {
                          // heroClient resolves to the actual server's client
                          // (Plex or Jellyfin) so each backend's transcoder
                          // builds sized URLs.
                          return blurArtwork(
                            CyclingMediaBackdrop(
                              mediaKey: heroItem.globalKey,
                              imagePaths: heroItem.heroRotationPaths(containerAspectRatio: heroAspectRatio),
                              fallbackImagePaths: heroArtPaths,
                              client: heroClient,
                              active: _isTabVisible,
                              width: screenWidth,
                              height: heroHeight,
                              fallbackColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                )
              else
                ColoredBox(color: colorScheme.surfaceContainerHighest),

              // Gradient Overlay - blends into scaffold background
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                bottom: -4, // Extend past stack bounds to ensure coverage
                child: IgnorePointer(
                  child: Builder(
                    builder: (context) {
                      final bgColor = Theme.of(context).scaffoldBackgroundColor;
                      return Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            // Reach full bg before the bottom edge so the hero
                            // blends seamlessly into the content below and the
                            // page dots sit on a solid band.
                            colors: [Colors.transparent, bgColor.withValues(alpha: 0.9), bgColor, bgColor],
                            stops: isTv ? const [0.25, 0.78, 0.94, 1.0] : const [0.5, 0.85, 0.94, 1.0],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),

              // Content with responsive alignment
              Positioned(
                bottom: isTv
                    ? 88
                    : compact
                    ? 24
                    : isLargeScreen
                    ? 80
                    : 50,
                left: 0,
                right: isTv
                    ? screenWidth * 0.36
                    : isLargeScreen
                    ? 200
                    : 0,
                // Horizontal-only SafeArea: the PageView artwork behind stays
                // full-bleed; the foreground text/buttons clear the landscape
                // notch. Vertical placement is handled by `bottom` above.
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: Padding(
                    padding: .symmetric(
                      horizontal: isTv
                          ? TvLayoutConstants.horizontalInset
                          : isLargeScreen
                          ? 40
                          : 24,
                    ),
                    child: Align(
                      alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isTv ? TvLayoutConstants.heroContentMaxWidth : double.infinity,
                        ),
                        child: Column(
                          crossAxisAlignment: alignLeft ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                          mainAxisSize: .min,
                          children: [
                            // Show logo, falling back to the name/title. The
                            // logo keeps its slot; the title gets a wider one.
                            LayoutBuilder(
                              builder: (context, constraints) => ClearLogoImage(
                                client: heroClient,
                                logoPath: heroItem.clearLogoPath,
                                width: math.min(heroLogoWidth, constraints.maxWidth),
                                height: heroLogoHeight,
                                fallbackWidth: ClearLogoImage.fallbackWidthFor(
                                  logoWidth: heroLogoWidth,
                                  available: constraints.maxWidth,
                                ),
                                alignment: alignLeft ? Alignment.bottomLeft : Alignment.bottomCenter,
                                // The hero scrim washes artwork toward the scaffold
                                // background; light themes recolor light-toned logos.
                                logoToneTarget: logoToneTargetFor(
                                  surface: theme.scaffoldBackgroundColor,
                                  foreground: colorScheme.onSurface,
                                ),
                                fallbackBuilder: (context) => FittingTitleText(
                                  showName,
                                  style: heroTitleStyle,
                                  textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                                  alignment: alignLeft ? Alignment.centerLeft : Alignment.center,
                                ),
                              ),
                            ),

                            // Metadata as dot-separated text with content type
                            if (heroItem.year != null || heroItem.contentRating != null || heroItem.rating != null) ...[
                              const SizedBox(height: 16),
                              Text(
                                [
                                  contentTypeLabel,
                                  if (heroItem.rating != null) '★ ${formatRating(heroItem.rating!)}',
                                  if (heroItem.contentRating != null) formatContentRating(heroItem.contentRating!),
                                  if (heroItem.year != null) heroItem.year.toString(),
                                ].join(' • '),
                                style: TextStyle(
                                  color: colorScheme.onSurface,
                                  fontSize: isTv ? 18 : 14,
                                  fontWeight: .w600,
                                ),
                                textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                              ),
                            ],

                            if (!alignLeft) ...[const SizedBox(height: 20), _buildSmartPlayButton(heroItem)],

                            if (heroItem.summary != null && !shouldHideSpoiler) ...[
                              const SizedBox(height: 12),
                              RichText(
                                maxLines: isTv ? 3 : 2,
                                overflow: .ellipsis,
                                textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                                text: TextSpan(
                                  style: TextStyle(
                                    color: colorScheme.onSurface.withValues(alpha: 0.7),
                                    fontSize: isTv ? 18 : 14,
                                    height: isTv ? 1.45 : 1.4,
                                  ),
                                  children: [
                                    if (isEpisode && heroItem.parentIndex != null && heroItem.index != null)
                                      TextSpan(
                                        text: 'S${heroItem.parentIndex}, E${heroItem.index}: ',
                                        style: TextStyle(fontWeight: .bold, color: colorScheme.onSurface),
                                      ),
                                    TextSpan(
                                      text: heroItem.summary?.isNotEmpty == true
                                          ? heroItem.summary!
                                          : t.messages.noDescriptionAvailable,
                                    ),
                                  ],
                                ),
                              ),
                            ] else if (shouldHideSpoiler &&
                                isEpisode &&
                                heroItem.parentIndex != null &&
                                heroItem.index != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                'S${heroItem.parentIndex}, E${heroItem.index}: ${heroItem.title}',
                                maxLines: 2,
                                overflow: .ellipsis,
                                textAlign: alignLeft ? TextAlign.left : TextAlign.center,
                                style: TextStyle(
                                  color: colorScheme.onSurface.withValues(alpha: 0.7),
                                  fontSize: isTv ? 18 : 14,
                                  height: isTv ? 1.45 : 1.4,
                                ),
                              ),
                            ],

                            if (alignLeft) ...[SizedBox(height: isTv ? 28 : 20), _buildSmartPlayButton(heroItem)],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSmartPlayButton(MediaItem rawHeroItem) {
    return Builder(
      builder: (context) {
        // The on-deck snapshot refetches shortly after a watch event; the store
        // patch bridges the gap so "minutes left" never lags.
        final heroItem = context.withFreshWatchState(rawHeroItem);
        final hasProgress = heroItem.hasActiveProgress;
        final isTv = PlatformDetector.isTV();

        final minutesLeft = hasProgress ? ((heroItem.durationMs! - heroItem.viewOffsetMs!) / 60_000).round() : 0;

        final progress = hasProgress ? heroItem.viewOffsetMs! / heroItem.durationMs! : 0.0;

        return ListenableBuilder(
          listenable: _heroFocusNode,
          builder: (context, _) {
            final showFocus = isTv && _heroFocusNode.hasFocus && InputModeTracker.isKeyboardMode(context);
            final colorScheme = Theme.of(context).colorScheme;
            final backgroundColor = showFocus ? colorScheme.primary : Colors.white;
            final foregroundColor = showFocus ? colorScheme.onPrimary : Colors.black;
            return InkWell(
              onTap: () {
                appLogger.d('Playing: ${heroItem.title}');
                navigateToVideoPlayer(context, metadata: heroItem);
              },
              borderRadius: BorderRadius.all(Radius.circular(isTv ? 32 : 24)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                padding: .symmetric(horizontal: isTv ? 34 : 24, vertical: isTv ? 16 : 12),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.all(Radius.circular(isTv ? 32 : 24)),
                  boxShadow: showFocus
                      ? [BoxShadow(color: colorScheme.primary.withValues(alpha: 0.35), blurRadius: 28, spreadRadius: 4)]
                      : null,
                ),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    AppIcon(Symbols.play_arrow_rounded, fill: 1, size: isTv ? 28 : 20, color: foregroundColor),
                    SizedBox(width: isTv ? 12 : 8),
                    if (hasProgress) ...[
                      // Progress bar
                      Container(
                        width: isTv ? 56 : 40,
                        height: isTv ? 8 : 6,
                        decoration: BoxDecoration(
                          color: foregroundColor.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.all(Radius.circular(isTv ? 4 : 3)),
                        ),
                        child: FractionallySizedBox(
                          alignment: .centerLeft,
                          widthFactor: progress,
                          child: Container(
                            decoration: BoxDecoration(
                              color: foregroundColor,
                              borderRadius: BorderRadius.all(Radius.circular(isTv ? 3 : 2)),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: isTv ? 12 : 8),
                      Text(
                        t.discover.minutesLeft(minutes: minutesLeft),
                        style: TextStyle(
                          color: foregroundColor,
                          fontSize: isTv ? 18 : 14,
                          fontWeight: isTv ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ] else
                      Text(
                        t.common.play,
                        style: TextStyle(
                          color: foregroundColor,
                          fontSize: isTv ? 18 : 14,
                          fontWeight: isTv ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
