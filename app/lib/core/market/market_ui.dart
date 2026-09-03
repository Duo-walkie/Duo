import 'package:one_one_app/one_one.dart';

/// Compact language control for the welcome screen (pre-auth).
///
/// Hidden for English-only markets. Selection is stored locally and carried
/// through sign-up, then mirrored onto user settings after authentication.
class WelcomeLanguageToggle extends StatelessWidget {
  const WelcomeLanguageToggle({super.key, this.foreground});

  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MarketSnapshot>(
      valueListenable: MarketController.snapshot,
      builder: (context, snapshot, _) {
        final config = snapshot.config;
        if (!config.offersLanguageChoice) {
          return const SizedBox.shrink();
        }
        return ValueListenableBuilder<Locale>(
          valueListenable: LocaleController.locale,
          builder: (context, locale, _) {
            final current = AppLanguage.fromLocale(locale);
            final color = foreground ?? const Color(0xff252a2e);
            return PopupMenuButton<AppLanguage>(
              tooltip: context.l10n.languageMenuTooltip,
              offset: const Offset(0, 40),
              color: Colors.white,
              onSelected: (language) {
                unawaited(LocaleController.setLanguage(language));
              },
              itemBuilder: (context) {
                return [
                  for (final language in config.supportedLanguages)
                    PopupMenuItem<AppLanguage>(
                      value: language,
                      child: Row(
                        children: [
                          Text(
                            language.flagEmoji,
                            style: const TextStyle(fontSize: 18),
                          ),
                          const SizedBox(width: 10),
                          if (language == current)
                            Icon(
                              Icons.check_rounded,
                              size: 18,
                              color: color,
                            )
                          else
                            const SizedBox(width: 18),
                          const SizedBox(width: 8),
                          Text(
                            language.nativeName,
                            style: TextStyle(
                              color: color,
                              fontWeight: language == current
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                ];
              },
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(20.r),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(current.flagEmoji, style: TextStyle(fontSize: 14.sp)),
                    SizedBox(width: 6.w),
                    Text(
                      current.nativeName,
                      style: TextStyle(
                        color: color,
                        fontSize: 12.sp,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(Icons.expand_more_rounded, size: 16.sp, color: color),
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

/// Settings rows for switching language after onboarding.
class SettingsLanguageSection extends StatelessWidget {
  const SettingsLanguageSection({
    super.key,
    required this.accent,
    required this.onLanguageSelected,
  });

  final Color accent;
  final Future<void> Function(AppLanguage language) onLanguageSelected;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MarketSnapshot>(
      valueListenable: MarketController.snapshot,
      builder: (context, snapshot, _) {
        final config = snapshot.config;
        if (!config.offersLanguageChoice) {
          return const SizedBox.shrink();
        }
        final l10n = context.l10n;
        return ValueListenableBuilder<Locale>(
          valueListenable: LocaleController.locale,
          builder: (context, locale, _) {
            final current = AppLanguage.fromLocale(locale);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 28),
                Text(
                  l10n.settingsLanguageSection.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Material(
                  color: const Color(0xff1b1b1b),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.language_rounded,
                              color: Colors.white70,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.settingsLanguageTitle,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    l10n.settingsLanguageSubtitle,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final language in config.supportedLanguages)
                          _ChoiceRow(
                            label: language.nativeName,
                            leading: language.flagEmoji,
                            selected: language == current,
                            accent: accent,
                            onTap: () =>
                                unawaited(onLanguageSelected(language)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Debug/QA market override. Compiled out of meaningful use in release.
class DebugMarketPanel extends StatelessWidget {
  const DebugMarketPanel({
    super.key,
    required this.accent,
    this.compact = false,
  });

  final Color accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return ValueListenableBuilder<MarketSnapshot>(
      valueListenable: MarketController.snapshot,
      builder: (context, snapshot, _) {
        final label =
            '${snapshot.isoCountryCode ?? snapshot.market.isoCode} · '
            '${snapshot.source.logLabel} · '
            '${snapshot.config.localeTagFor(LocaleController.language)}';
        if (compact) {
          return GestureDetector(
            onTap: () => unawaited(_openPicker(context)),
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xff252a2e).withValues(alpha: 0.55),
                  fontSize: 11.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 28),
            const Text(
              'DEBUG MARKET',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Material(
              color: const Color(0xff1b1b1b),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  children: [
                    Text(
                      'QA only. Release builds ignore this override.\n$label',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _ChoiceRow(
                      label: 'Automatic',
                      selected: snapshot.source != MarketSource.debugOverride,
                      accent: accent,
                      onTap: () =>
                          unawaited(MarketController.setDebugOverride(null)),
                    ),
                    for (final market in Market.values)
                      if (market != Market.unknown)
                        _ChoiceRow(
                          label: market.debugLabel,
                          selected:
                              snapshot.source == MarketSource.debugOverride &&
                              snapshot.market == market,
                          accent: accent,
                          onTap: () => unawaited(
                            MarketController.setDebugOverride(market),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _openPicker(BuildContext context) async {
    if (!kDebugMode) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff1b1b1b),
      builder: (context) {
        return SafeArea(
          child: DebugMarketPanel(
            accent: accentColorForKey(AccentThemeController.accentKey.value),
          ),
        );
      },
    );
  }
}

/// Resolves the onboarding/welcome body from [MarketConfig.onboardingVariant]
/// so a future country-specific screen can be added without forking the app.
class WelcomeOnboardingHost extends StatelessWidget {
  const WelcomeOnboardingHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MarketSnapshot>(
      valueListenable: MarketController.snapshot,
      builder: (context, snapshot, _) {
        final variant = snapshot.config.onboardingVariant;
        // Phase 1 shares one welcome layout. Explicit cases keep the variant
        // map in one place for India / USA / Germany / … screens later.
        return switch (variant) {
          OnboardingVariant.india ||
          OnboardingVariant.usa ||
          OnboardingVariant.unitedKingdom ||
          OnboardingVariant.germany ||
          OnboardingVariant.france ||
          OnboardingVariant.spain ||
          OnboardingVariant.italy ||
          OnboardingVariant.defaultVariant => child,
        };
      },
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.leading,
  });

  final String label;
  final String? leading;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off_outlined,
              color: selected ? accent : Colors.white38,
              size: 22,
            ),
            const SizedBox(width: 12),
            if (leading != null) ...[
              Text(leading!, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
