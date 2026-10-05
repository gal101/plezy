import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../models/tunarr/tunarr_session.dart';
import '../../providers/tunarr_account_provider.dart';
import '../../services/settings_service.dart';
import '../../services/tunarr/tunarr_exceptions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';

/// Single-step Tunarr connect flow: enter the gate address, then sign in with
/// the profile's stored Plex token.
///
/// Unlike Seerr there is nothing to probe or pick: the gate's
/// `POST /api/v1/auth/plex` answers on the body
/// (`{granted, username, email, plexId, sections}`) and issues no cookie, so a
/// reachable URL and a Plex token are all sign-in needs. The finished
/// [TunarrSession] goes to [TunarrAccountProvider.adoptSession], the GalTV tab
/// is switched on, and the screen pops.
class TunarrConnectScreen extends StatefulWidget {
  const TunarrConnectScreen({super.key});

  @override
  State<TunarrConnectScreen> createState() => _TunarrConnectScreenState();
}

class _TunarrConnectScreenState extends State<TunarrConnectScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'TunarrConnect:Url');
  final _signInFocus = FocusNode(debugLabel: 'TunarrConnect:SignIn');

  @override
  void dispose() {
    _urlFocus.dispose();
    _signInFocus.dispose();
    super.dispose();
  }

  Future<void> _signInWithPlex() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) {
      setErrorText(t.addServer.required);
      return;
    }
    await runAsync<void>(() async {
      final account = context.read<TunarrAccountProvider>();
      // The provider resolves the live Plex token and normalizes the URL.
      final session = await account.signIn(baseUrl: input);
      await _finish(account, session);
    }, errorMapper: _describeError);
  }

  Future<void> _finish(TunarrAccountProvider account, TunarrSession session) async {
    await account.adoptSession(session);
    // Connecting is the user asking for the GalTV surface: switch its tab on so
    // the navigation reflects the newly linked instance without a second step.
    await SettingsService.instance.write(SettingsService.enableGaltv, true);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  String _describeError(Object e) => switch (e) {
    TunarrFailure(:final message, :final display) => display ?? message,
    // The provider throws this when the profile has no Plex token (e.g. a
    // Jellyfin-only setup) — sign-in cannot proceed without one.
    StateError() => t.seerr.noPlexTokenForReauth,
    _ => t.addServer.couldNotReachServer(error: e.toString()),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.tunarr.connectTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FocusableTextFormField(
                  controller: _urlController,
                  focusNode: _urlFocus,
                  autofocus: true,
                  tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !busy,
                  onNavigateDown: () => _signInFocus.requestFocus(),
                  textInputAction: TextInputAction.go,
                  onFieldSubmitted: busy ? null : (_) => _signInWithPlex(),
                  decoration: InputDecoration(
                    labelText: t.tunarr.serverUrl,
                    // URL example — intentionally not localized.
                    hintText: 'https://tunarr.example.com',
                    prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
                  ),
                ),
                const SizedBox(height: 16),
                FocusableButton(
                  focusNode: _signInFocus,
                  useBackgroundFocus: true,
                  onNavigateUp: () => _urlFocus.requestFocus(),
                  onPressed: busy ? null : _signInWithPlex,
                  child: FilledButton.icon(
                    onPressed: busy ? null : _signInWithPlex,
                    icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
                    label: Text(t.tunarr.signInWithPlex),
                  ),
                ),
                ...buildInlineError(theme),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
