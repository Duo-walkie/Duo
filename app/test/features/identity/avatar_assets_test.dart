import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int countPngsOnDisk(String folder) {
    final dir = Directory('assets/$folder');
    return dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.png'))
        .length;
  }

  test('enumerates every bundled avatar without hardcoding a count', () async {
    final avatars = await AvatarAssets.loadAll();

    final current = avatars.where((a) => a.pack == AvatarPack.current);

    expect(current.length, countPngsOnDisk('avatars_new'));
    expect(avatars.length, current.length);

    // No duplicates, and every path actually points at the pack it's
    // grouped under.
    expect(avatars.map((a) => a.assetPath).toSet().length, avatars.length);
    for (final avatar in avatars) {
      expect(avatar.assetPath.startsWith(avatar.pack.assetPrefix), isTrue);
    }
  });

  test('every enumerated avatar loads from the asset bundle', () async {
    final avatars = await AvatarAssets.loadAll();
    expect(avatars, isNotEmpty);

    for (final avatar in avatars) {
      final bytes = await rootBundle.load(avatar.assetPath);
      expect(
        bytes.lengthInBytes,
        greaterThan(0),
        reason: '${avatar.assetPath} should not be empty',
      );
    }
  });

  test('isPresetAvatarPath validates current preset paths only', () {
    expect(
      AvatarAssets.isPresetAvatarPath('assets/avatars_new/cute-duck.png'),
      isTrue,
    );
    expect(
      AvatarAssets.isPresetAvatarPath('assets/avatars/avatar_01.png'),
      isFalse,
    );
    expect(
      AvatarAssets.isPresetAvatarPath('assets/avatars2/avatar_42.png'),
      isFalse,
    );
    expect(
      AvatarAssets.isPresetAvatarPath('https://example.com/photo.jpg'),
      isFalse,
    );
    expect(AvatarAssets.isPresetAvatarPath('assets/logo.png'), isFalse);
  });

  test('isRetiredAvatarPath matches the old Classic and Studio packs', () {
    expect(
      AvatarAssets.isRetiredAvatarPath('assets/avatars/avatar_01.png'),
      isTrue,
    );
    expect(
      AvatarAssets.isRetiredAvatarPath('assets/avatars2/avatar_42.png'),
      isTrue,
    );
    expect(
      AvatarAssets.isRetiredAvatarPath('assets/avatars_new/cute-duck.png'),
      isFalse,
    );
    expect(AvatarAssets.isRetiredAvatarPath(''), isFalse);
  });

  test('needsRefresh only when a retired avatar is the only face', () {
    expect(
      AvatarAssets.needsRefresh(avatarAsset: 'assets/avatars/avatar_01.png'),
      isTrue,
    );
    expect(
      AvatarAssets.needsRefresh(avatarAsset: 'assets/avatars2/avatar_08.png'),
      isTrue,
    );
    expect(
      AvatarAssets.needsRefresh(
        avatarAsset: 'assets/avatars/avatar_01.png',
        profilePhotoUrl: 'https://example.com/photo.jpg',
      ),
      isFalse,
    );
    expect(
      AvatarAssets.needsRefresh(avatarAsset: 'assets/avatars_new/cute-duck.png'),
      isFalse,
    );
    expect(AvatarAssets.needsRefresh(avatarAsset: null), isFalse);
    expect(AvatarAssets.needsRefresh(avatarAsset: ''), isFalse);
  });
}
