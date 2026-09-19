import 'package:one_one_app/one_one.dart';

class AccentOption {
  const AccentOption({
    required this.key,
    required this.label,
    required this.color,
  });

  final String key;
  final String label;
  final Color color;

  String localizedLabel(AppLocalizations l10n) => switch (key) {
    'coral' => l10n.accentCoral,
    'lime' => l10n.accentLime,
    'sky' => l10n.accentSky,
    'violet' => l10n.accentViolet,
    'amber' => l10n.accentAmber,
    'pink' => l10n.accentPink,
    'teal' => l10n.accentTeal,
    'indigo' => l10n.accentIndigo,
    'orange' => l10n.accentOrange,
    'mint' => l10n.accentMint,
    'yellow' => l10n.accentYellow,
    'cyan' => l10n.accentCyan,
    _ => label,
  };
}

const List<AccentOption> accentOptions = [
  AccentOption(key: 'coral', label: 'Coral', color: Color(0xffff5a5f)),
  AccentOption(key: 'lime', label: 'Lime', color: Color(0xff9bdc28)),
  AccentOption(key: 'sky', label: 'Sky', color: Color(0xff25a9ff)),
  AccentOption(key: 'violet', label: 'Violet', color: Color(0xff8b5cf6)),
  AccentOption(key: 'amber', label: 'Amber', color: Color(0xffffb020)),
  AccentOption(key: 'pink', label: 'Pink', color: Color(0xffec4899)),
  AccentOption(key: 'teal', label: 'Teal', color: Color(0xff00b8a9)),
  AccentOption(key: 'indigo', label: 'Indigo', color: Color(0xff6366f1)),
  AccentOption(key: 'orange', label: 'Orange', color: Color(0xffff7a3d)),
  AccentOption(key: 'mint', label: 'Mint', color: Color(0xff34d399)),
  AccentOption(key: 'yellow', label: 'Yellow', color: Color(0xffeab308)),
  AccentOption(key: 'cyan', label: 'Cyan', color: Color(0xff22d3ee)),
];

Color accentColorForKey(String key) {
  for (final option in accentOptions) {
    if (option.key == key) return option.color;
  }

  return accentOptions.first.color;
}

class AccentThemeController {
  AccentThemeController._();

  static final ValueNotifier<String> accentKey = ValueNotifier<String>(
    accentOptions.first.key,
  );

  static void setAccentKey(String key) {
    final next = accentOptions.any((option) => option.key == key)
        ? key
        : accentOptions.first.key;
    // Avoid notifying listeners when nothing changed — a root rebuild of
    // MaterialApp-dependent trees while widgets are mid-save/pop can crash.
    if (accentKey.value == next) return;
    void apply() {
      if (accentKey.value == next) return;
      accentKey.value = next;
    }

    // IdentityHomeScreen is first inserted as StartupGateScreen's child
    // during that screen's build. Notifying the root ValueListenableBuilder
    // in the same frame marks it dirty while StartupGateScreen is still
    // building and fatals with setState-during-build.
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      apply();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }
}
