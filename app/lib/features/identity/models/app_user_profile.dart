class AppUserProfile {
  const AppUserProfile({
    required this.userId,
    required this.displayName,
    required this.authProvider,
    required this.accountState,
    required this.createdAt,
    required this.updatedAt,
    required this.lastSeenAt,
    this.setupCompleted = false,
    this.profilePhotoUrl,
    this.profilePhotoBase64,
    this.avatarAsset,
    this.market,
  });

  final String userId;
  final String displayName;
  final String authProvider;
  final String accountState;
  final int createdAt;
  final int updatedAt;
  final int lastSeenAt;
  final bool setupCompleted;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;

  /// ISO 3166-1 alpha-2 Play/account market, e.g. `DE`. Independent of locale.
  final String? market;

  bool get hasProfilePhoto {
    final url = profilePhotoUrl?.trim();
    if (url != null && url.isNotEmpty) {
      return true;
    }

    final encodedPhoto = profilePhotoBase64?.trim();
    if (encodedPhoto != null && encodedPhoto.isNotEmpty) return true;
    final avatar = avatarAsset?.trim();
    return avatar != null && avatar.isNotEmpty;
  }

  Map<String, Object?> toJson() {
    final data = <String, Object?>{
      'displayName': displayName,
      'authProvider': authProvider,
      'accountState': accountState,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'lastSeenAt': lastSeenAt,
      'setupCompleted': setupCompleted,
    };

    if (profilePhotoUrl != null) {
      data['profilePhotoUrl'] = profilePhotoUrl;
    }

    if (profilePhotoBase64 != null) {
      data['profilePhotoBase64'] = profilePhotoBase64;
    }

    if (avatarAsset != null) data['avatarAsset'] = avatarAsset;
    if (market != null && market!.trim().isNotEmpty) {
      data['market'] = market!.trim().toUpperCase();
    }

    return data;
  }

  static AppUserProfile fromJson(String userId, Map<Object?, Object?> data) {
    return AppUserProfile(
      userId: userId,
      displayName: data['displayName']?.toString() ?? '',
      authProvider: data['authProvider']?.toString() ?? 'anonymous',
      accountState: data['accountState']?.toString() ?? 'active',
      createdAt: _readInt(data['createdAt']),
      updatedAt: _readInt(data['updatedAt']),
      lastSeenAt: _readInt(data['lastSeenAt']),
      setupCompleted: data['setupCompleted'] == true,
      profilePhotoUrl: data['profilePhotoUrl']?.toString(),
      profilePhotoBase64: data['profilePhotoBase64']?.toString(),
      avatarAsset: data['avatarAsset']?.toString(),
      market: data['market']?.toString(),
    );
  }

  AppUserProfile copyWith({
    String? displayName,
    String? authProvider,
    int? updatedAt,
    int? lastSeenAt,
    bool? setupCompleted,
    String? profilePhotoUrl,
    String? profilePhotoBase64,
    String? avatarAsset,
    String? market,
    bool clearProfilePhotoUrl = false,
    bool clearProfilePhotoBase64 = false,
    bool clearAvatarAsset = false,
  }) {
    return AppUserProfile(
      userId: userId,
      displayName: displayName ?? this.displayName,
      authProvider: authProvider ?? this.authProvider,
      accountState: accountState,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      setupCompleted: setupCompleted ?? this.setupCompleted,
      profilePhotoUrl: clearProfilePhotoUrl
          ? null
          : (profilePhotoUrl ?? this.profilePhotoUrl),
      profilePhotoBase64: clearProfilePhotoBase64
          ? null
          : (profilePhotoBase64 ?? this.profilePhotoBase64),
      avatarAsset: clearAvatarAsset ? null : (avatarAsset ?? this.avatarAsset),
      market: market ?? this.market,
    );
  }
}

bool hasCompletedProfileSetup(
  AppUserProfile profile, {
  required bool isLegacyProfile,
}) {
  return profile.setupCompleted ||
      (isLegacyProfile &&
          profile.displayName.trim().isNotEmpty &&
          profile.hasProfilePhoto);
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
