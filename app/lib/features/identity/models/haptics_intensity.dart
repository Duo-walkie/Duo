import 'package:one_one_app/l10n/l10n.dart';

/// Three-tier haptic intensity for incoming voice-nudge playback.
/// Light is the historical default: two bursts at start and two at end.
/// Medium (Pulse) plays a double-double burst pattern. Wild vibrates
/// continuously for the whole voice nudge. Other in-app feedback (recording
/// press, talk, UI taps) uses fixed defaults and ignores this preference.
enum HapticsIntensity {
  light,
  medium,
  wild;

  static const HapticsIntensity defaultValue = light;

  static HapticsIntensity parse(String? value) {
    return switch (value) {
      'medium' => medium,
      'wild' => wild,
      _ => light,
    };
  }

  String get storageKey => name;

  String get emoji => switch (this) {
    light => '🌿',
    medium => '⚡',
    wild => '🔥',
  };

  String get label => switch (this) {
    light => 'Light',
    medium => 'Pulse',
    wild => 'Wild',
  };

  String get subtitle => switch (this) {
    light => 'Two taps at the start and two at the end.',
    medium => 'A double-double burst — two quick pairs.',
    wild => 'Continuous vibration for the whole nudge.',
  };

  String localizedLabel(AppLocalizations l10n) => switch (this) {
    light => l10n.hapticsLight,
    medium => l10n.hapticsPulse,
    wild => l10n.hapticsWild,
  };

  String localizedSubtitle(AppLocalizations l10n) => switch (this) {
    light => l10n.hapticsLightDetail,
    medium => l10n.hapticsPulseDetail,
    wild => l10n.hapticsWildDetail,
  };
}
