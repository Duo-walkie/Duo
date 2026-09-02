import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  AppUserProfile profile({
    bool setupCompleted = false,
    String displayName = '',
    String? profilePhotoUrl,
  }) {
    return AppUserProfile(
      userId: 'user',
      displayName: displayName,
      authProvider: 'google',
      accountState: 'active',
      createdAt: 1,
      updatedAt: 1,
      lastSeenAt: 1,
      setupCompleted: setupCompleted,
      profilePhotoUrl: profilePhotoUrl,
    );
  }

  test('explicit completion survives reinstall', () {
    expect(
      hasCompletedProfileSetup(
        profile(setupCompleted: true),
        isLegacyProfile: false,
      ),
      isTrue,
    );
  });

  test('legacy completed profile is migrated without onboarding', () {
    expect(
      hasCompletedProfileSetup(
        profile(
          displayName: 'Asha',
          profilePhotoUrl: 'https://example.com/photo.jpg',
        ),
        isLegacyProfile: true,
      ),
      isTrue,
    );
    expect(
      hasCompletedProfileSetup(
        profile(displayName: 'Asha'),
        isLegacyProfile: true,
      ),
      isFalse,
    );
  });

  test('new partial profile cannot trigger legacy migration', () {
    expect(
      hasCompletedProfileSetup(
        profile(
          displayName: 'Google default',
          profilePhotoUrl: 'https://example.com/photo.jpg',
        ),
        isLegacyProfile: false,
      ),
      isFalse,
    );
  });

  test('preset avatar is persisted without a photo upload', () {
    final avatar = profile().copyWith(
      avatarAsset: 'assets/avatars/avatar_01.png',
    );

    expect(avatar.toJson()['avatarAsset'], 'assets/avatars/avatar_01.png');
    expect(avatar.hasProfilePhoto, isTrue);
  });

  test('copyWith clearAvatarAsset drops the preset', () {
    final avatar = profile().copyWith(
      avatarAsset: 'assets/avatars/avatar_01.png',
    );
    final cleared = avatar.copyWith(
      clearAvatarAsset: true,
      profilePhotoUrl: 'https://example.com/photo.jpg',
    );

    expect(cleared.avatarAsset, isNull);
    expect(cleared.profilePhotoUrl, 'https://example.com/photo.jpg');
  });

  test('market is optional and round-trips', () {
    final stored = profile(displayName: 'Asha').copyWith(market: 'DE');
    expect(stored.market, 'DE');
    expect(stored.toJson()['market'], 'DE');
    expect(AppUserProfile.fromJson('user', stored.toJson()).market, 'DE');
  });
}
