import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/tunarr_account_provider.dart';
import '../../services/settings_service.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_page.dart';
import '../../widgets/settings_section.dart';

/// Connected-state settings for the Tunarr instance: who is signed in, which
/// instance, the GalTV tab toggle, and disconnect.
class TunarrSettingsScreen extends StatelessWidget {
  const TunarrSettingsScreen({super.key});

  Future<void> _disconnect(BuildContext context, TunarrAccountProvider account) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.tunarr.disconnectConfirm,
      message: t.tunarr.disconnectConfirmBody,
      confirmText: t.common.disconnect,
      isDestructive: true,
    );
    if (!confirmed) return;
    await account.disconnect();
    // build()'s post-frame handler pops the screen once the provider rebuilds
    // with isConnected == false — don't pop here too.
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<TunarrAccountProvider>(
      builder: (context, account, _) {
        final session = account.session;
        // Safety net: if the session got invalidated in the background, bail
        // out — the Services hub row is the entry point for reconnecting.
        if (session == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
          return SettingsPage(title: Text(t.tunarr.title), children: const []);
        }

        return SettingsPage(
          title: Text(t.tunarr.title),
          children: [
            SettingsGroup(
              children: [
                ListTile(
                  leading: const AppIcon(Symbols.account_circle_rounded, fill: 1),
                  title: Text(t.services.connectedAs(username: account.displayName)),
                ),
                ListTile(
                  leading: const AppIcon(Symbols.dns_rounded, fill: 1),
                  title: Text(session.instanceLabel.isNotEmpty ? session.instanceLabel : t.tunarr.instance),
                  subtitle: Text(session.baseUrl),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              children: [
                SettingSwitchTile(
                  pref: SettingsService.enableGaltv,
                  icon: Symbols.tv_rounded,
                  title: t.tunarr.galtvToggle,
                  subtitle: t.tunarr.galtvToggleSubtitle,
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              children: [
                FocusableListTile(
                  leading: AppIcon(Symbols.link_off_rounded, fill: 1, color: Theme.of(context).colorScheme.error),
                  title: Text(t.common.disconnect, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  onTap: () => unawaited(_disconnect(context, account)),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}
