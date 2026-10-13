import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/media_source_info.dart';
import '../../../theme/mono_tokens.dart';
import '../../app_icon.dart';

class SkipMarkerButton extends StatelessWidget {
  /// The marker being offered, or null for the GalTV filler case, where the slot
  /// offers the next programme and there is no marker to describe.
  final MediaMarker? marker;
  final Duration playerDuration;
  final bool hasNextEpisode;
  final bool isAutoSkipActive;
  final bool shouldShowAutoSkip;
  final int autoSkipDelay;
  final double autoSkipProgress;
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final VoidCallback onFocusDown;

  const SkipMarkerButton({
    super.key,
    this.marker,
    required this.playerDuration,
    required this.hasNextEpisode,
    required this.isAutoSkipActive,
    required this.shouldShowAutoSkip,
    required this.autoSkipDelay,
    required this.autoSkipProgress,
    required this.focusNode,
    required this.onActivate,
    required this.onFocusDown,
    this.galTvUpNext = false,
  });

  /// Renders the **GalTV "Up next"** affordance instead of a skip prompt.
  ///
  /// Same slot in the chrome, different question: on a live channel the credits
  /// are not something to skip past — there is no next episode of a channel, only
  /// whatever the schedule holds next. So the label becomes the slate's own name
  /// and the countdown is suppressed (a live channel never auto-fires this).
  final bool galTvUpNext;

  @override
  Widget build(BuildContext context) {
    final isCredits = marker?.isCredits ?? false;
    final creditsAtEnd =
        isCredits && playerDuration > Duration.zero && (playerDuration - marker!.endTime).inMilliseconds <= 1000;
    // Only a marker can end at the file's end; the GalTV filler slot never does.
    final showNextEpisode = creditsAtEnd && hasNextEpisode;
    String baseButtonText;
    if (galTvUpNext) {
      baseButtonText = t.galtv.upNext;
    } else if (showNextEpisode) {
      baseButtonText = t.videoControls.nextEpisode;
    } else if (isCredits) {
      baseButtonText = t.videoControls.skipCredits;
    } else {
      baseButtonText = t.videoControls.skipIntro;
    }

    final remainingSeconds = isAutoSkipActive && shouldShowAutoSkip
        ? (autoSkipDelay - (autoSkipProgress * autoSkipDelay)).ceil().clamp(0, autoSkipDelay)
        : 0;

    final showAutoSkipCountdown = !galTvUpNext && isAutoSkipActive && shouldShowAutoSkip;
    final buttonText = showAutoSkipCountdown && remainingSeconds > 0
        ? '$baseButtonText ($remainingSeconds)'
        : baseButtonText;
    final buttonIcon = galTvUpNext
        ? Symbols.play_circle_rounded
        : showNextEpisode
        ? Symbols.skip_next_rounded
        : Symbols.fast_forward_rounded;

    return FocusableWrapper(
      focusNode: focusNode,
      onSelect: _activate,
      borderRadius: tokens(context).radiusSm,
      useBackgroundFocus: true,
      autoScroll: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
          onFocusDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _activate,
          borderRadius: BorderRadius.circular(tokens(context).radiusSm),
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 2)),
                  ],
                ),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    Text(
                      buttonText,
                      style: const TextStyle(color: Colors.black, fontSize: 16, fontWeight: .w600),
                    ),
                    const SizedBox(width: 8),
                    AppIcon(buttonIcon, fill: 1, color: Colors.black, size: 20),
                  ],
                ),
              ),
              if (isAutoSkipActive && shouldShowAutoSkip)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                    child: Row(
                      children: [
                        Expanded(
                          flex: (autoSkipProgress * 100).round(),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(tokens(context).radiusSm),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: ((1.0 - autoSkipProgress) * 100).round(),
                          child: Container(decoration: const BoxDecoration(color: Colors.transparent)),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _activate() => onActivate();
}
