import 'package:one_one_app/one_one.dart';

class UserSettingsRecord {
  const UserSettingsRecord({
    required this.accentColorKey,
    required this.hapticsIntensity,
    required this.audioOutputPreference,
    required this.autoOnlineOnLaunch,
    required this.updatedAt,
    this.preferredLocale,
  });

  final String accentColorKey;
  final HapticsIntensity hapticsIntensity;

  /// Legacy field kept on the wire for older clients. Audio routing is
  /// automatic (speaker, or the connected headset/Bluetooth device) and is
  /// no longer a user-facing setting.
  final String audioOutputPreference;
  final bool autoOnlineOnLaunch;
  final int updatedAt;

  /// BCP-47 language code (`en`, `fr`, `de`, `es`, `ja`). Independent of market.
  final String? preferredLocale;

  /// All three haptic tiers produce feedback; this stays true so existing
  /// call sites that only gate "should I vibrate at all?" keep working.
  bool get hapticsEnabled => true;

  Map<String, Object?> toJson() {
    return {
      'accentColorKey': accentColorKey,
      'hapticsIntensity': hapticsIntensity.storageKey,
      'hapticsEnabled': true,
      'audioOutputPreference': audioOutputPreference,
      'autoOnlineOnLaunch': autoOnlineOnLaunch,
      'updatedAt': updatedAt,
      if (preferredLocale != null && preferredLocale!.trim().isNotEmpty)
        'preferredLocale': preferredLocale!.trim(),
    };
  }

  static UserSettingsRecord defaults(int now) {
    return UserSettingsRecord(
      accentColorKey: 'coral',
      hapticsIntensity: HapticsIntensity.defaultValue,
      audioOutputPreference: 'speaker',
      autoOnlineOnLaunch: false,
      updatedAt: now,
    );
  }

  static UserSettingsRecord fromJson(Map<Object?, Object?> data) {
    final audioOutputPreference = data['audioOutputPreference']?.toString();

    return UserSettingsRecord(
      accentColorKey: data['accentColorKey']?.toString() ?? 'coral',
      hapticsIntensity: HapticsIntensity.parse(
        data['hapticsIntensity']?.toString(),
      ),
      audioOutputPreference: audioOutputPreference == 'earpiece'
          ? 'earpiece'
          : 'speaker',
      autoOnlineOnLaunch: data['autoOnlineOnLaunch'] == true,
      updatedAt: _readInt(data['updatedAt']),
      preferredLocale: data['preferredLocale']?.toString(),
    );
  }

  UserSettingsRecord copyWith({
    String? accentColorKey,
    HapticsIntensity? hapticsIntensity,
    String? audioOutputPreference,
    bool? autoOnlineOnLaunch,
    int? updatedAt,
    String? preferredLocale,
  }) {
    return UserSettingsRecord(
      accentColorKey: accentColorKey ?? this.accentColorKey,
      hapticsIntensity: hapticsIntensity ?? this.hapticsIntensity,
      audioOutputPreference:
          audioOutputPreference ?? this.audioOutputPreference,
      autoOnlineOnLaunch: autoOnlineOnLaunch ?? this.autoOnlineOnLaunch,
      updatedAt: updatedAt ?? this.updatedAt,
      preferredLocale: preferredLocale ?? this.preferredLocale,
    );
  }
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
