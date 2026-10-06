import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/navigation/navigation_tabs.dart';

/// The "GalTV tab overrides Live TV" rule: Live TV loses its tab *only* while
/// GalTV is actually available, so signing out of Tunarr (or switching the GalTV
/// tab off) always brings Live TV back, and the shell never resolves its default
/// tab to one the navigation is hiding.
void main() {
  List<NavigationTabId> visible({required bool hasLiveTv, required bool hasGalTv, required bool overrides}) =>
      NavigationTab.getVisibleTabs(
        isOffline: false,
        hasLiveTv: hasLiveTv,
        hasGalTv: hasGalTv,
        galTvOverridesLiveTv: overrides,
      ).map((tab) => tab.id).toList();

  test('an available GalTV replaces Live TV when the toggle is on', () {
    final tabs = visible(hasLiveTv: true, hasGalTv: true, overrides: true);
    expect(tabs, contains(NavigationTabId.galtv));
    expect(tabs, isNot(contains(NavigationTabId.liveTv)));
  });

  test('turning the toggle off keeps both tabs', () {
    final tabs = visible(hasLiveTv: true, hasGalTv: true, overrides: false);
    expect(tabs, containsAll([NavigationTabId.liveTv, NavigationTabId.galtv]));
  });

  test('Live TV comes back when GalTV is not available, whatever the toggle says', () {
    // Signed out of Tunarr, or the GalTV tab switched off in its own settings.
    expect(visible(hasLiveTv: true, hasGalTv: false, overrides: true), contains(NavigationTabId.liveTv));
    expect(visible(hasLiveTv: true, hasGalTv: false, overrides: true), isNot(contains(NavigationTabId.galtv)));
  });

  test('the default tab never resolves to a replaced Live TV', () {
    final tab = NavigationTab.resolveDefaultTab(
      isOffline: false,
      hasLiveTv: true,
      hasGalTv: true,
      galTvOverridesLiveTv: true,
      preferredStartup: NavigationTabId.liveTv,
    );
    expect(tab, isNot(NavigationTabId.liveTv), reason: 'a hidden tab cannot be the startup tab');
  });
}
