part of '../../identity_home_screen.dart';

// 1. Settings / setup / presence / audio controls.
// 2. Status toggle, glass buttons, speaker/mute glyph.

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.onSettings,
    required this.onSetup,
    required this.hasSetupWarnings,
    required this.busy,
    required this.online,
    required this.enabled,
    required this.onTogglePresence,
    required this.showAudioOutput,
    required this.speakerOn,
    required this.audioRoute,
    required this.audioMuted,
    required this.onToggleAudioOutput,
    required this.onToggleAudioMute,
  });

  final VoidCallback onSettings;
  final VoidCallback onSetup;
  final bool hasSetupWarnings;
  final bool busy;
  final bool online;
  final bool enabled;
  final VoidCallback onTogglePresence;
  final bool showAudioOutput;
  final bool speakerOn;
  final AudioOutputRoute audioRoute;
  final bool audioMuted;
  final VoidCallback onToggleAudioOutput;
  final VoidCallback onToggleAudioMute;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12.w, 4.h, 12.w, 0),
      child: SizedBox(
        height: 52.h,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: Image.asset(
                'assets/logo.png',
                height: 44.h,
                fit: BoxFit.contain,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _GlassIconButton(
                        tooltip: hasSetupWarnings
                            ? context.l10n.homeSettingsSetup
                            : context.l10n.homeSettings,
                        icon: Icons.settings_outlined,
                        onPressed: onSettings,
                        onLongPress: onSetup,
                      ),
                      if (hasSetupWarnings)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: GestureDetector(
                            onTap: onSetup,
                            child: Container(
                              width: 14.w,
                              height: 14.w,
                              decoration: const BoxDecoration(
                                color: Color(0xffff5a5f),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (showAudioOutput) ...[
                    SizedBox(width: 6.w),
                    _AudioOutputSwitchIcon(
                      speakerOn: speakerOn,
                      route: audioRoute,
                      muted: audioMuted,
                      onToggle: onToggleAudioOutput,
                      onMute: onToggleAudioMute,
                    ),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              // No text label under the toggle by design - its state (and a
              // description for accessibility) is conveyed by the switch
              // itself plus its Tooltip/Semantics.
              child: _StatusToggle(
                busy: busy,
                online: online,
                enabled: enabled,
                onToggle: onTogglePresence,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusToggle extends StatelessWidget {
  const _StatusToggle({
    required this.busy,
    required this.online,
    required this.enabled,
    required this.onToggle,
  });

  final bool busy;
  final bool online;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: busy || !enabled ? 0.55 : 1,
      child: Tooltip(
        message: !enabled
            ? context.l10n.homeStatusUnavailable
            : online
            ? context.l10n.homeStatusGoAway
            : context.l10n.homeStatusGoOnline,
        child: SizedBox(
          width: 66.w,
          height: 40,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: busy || !enabled ? null : onToggle,
              borderRadius: BorderRadius.circular(20),
              child: Center(
                child: Container(
                  width: double.infinity,
                  height: 24.h,
                  padding: EdgeInsets.all(2.w),
                  decoration: BoxDecoration(
                    color: const Color.fromRGBO(255, 255, 255, 0.12),
                    borderRadius: BorderRadius.circular(14.r),
                    border: Border.all(
                      color: const Color.fromRGBO(255, 255, 255, 0.22),
                    ),
                  ),
                  child: Stack(
                    children: [
                      AnimatedAlign(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: online
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          width: 30.w,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: online
                                ? const Color(0xff7CFF6B)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(11.r),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Center(
                              // Matches the profile-picture away moon badge
                              // (Icons.dark_mode_rounded @ ~13.sp).
                              child: Icon(
                                Icons.dark_mode_rounded,
                                color: online
                                    ? Colors.white54
                                    : const Color(0xff2a2a2a),
                                size: 13.sp,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Center(
                              child: busy
                                  ? Text('…', style: TextStyle(fontSize: 10.sp))
                                  : online
                                  ? Text(
                                      '🟢',
                                      style: TextStyle(fontSize: 10.sp),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    this.icon,
    this.child,
    required this.onPressed,
    this.onLongPress,
  });

  final String tooltip;
  final IconData? icon;
  final Widget? child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(22.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onPressed == null
                ? const Color.fromRGBO(255, 255, 255, 0.06)
                : const Color.fromRGBO(0, 0, 0, 0.35),
            border: Border.all(
              color: const Color.fromRGBO(255, 255, 255, 0.18),
            ),
          ),
          child:
              child ??
              Icon(
                icon,
                color: onPressed == null ? Colors.white38 : Colors.white,
                size: 22.sp,
              ),
        ),
      ),
    );
  }
}

class _AudioOutputSwitchIcon extends StatefulWidget {
  const _AudioOutputSwitchIcon({
    required this.speakerOn,
    required this.route,
    required this.muted,
    required this.onToggle,
    required this.onMute,
  });

  final bool speakerOn;
  final AudioOutputRoute route;
  final bool muted;
  final VoidCallback onToggle;
  final VoidCallback onMute;

  @override
  State<_AudioOutputSwitchIcon> createState() => _AudioOutputSwitchIconState();
}

class _AudioOutputSwitchIconState extends State<_AudioOutputSwitchIcon> {
  @override
  Widget build(BuildContext context) {
    final kind = resolveAudioOutputGlyph(
      route: widget.route,
      muted: widget.muted,
    );
    return _GlassIconButton(
      tooltip: audioOutputTooltip(
        kind: kind,
        speakerPreferenceOn: widget.speakerOn,
      ),
      onPressed: widget.onToggle,
      onLongPress: widget.onMute,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: LucideAudioGlyph(
          key: ValueKey(kind),
          kind: kind,
          color: Colors.white,
          size: 22.sp,
        ),
      ),
    );
  }
}
