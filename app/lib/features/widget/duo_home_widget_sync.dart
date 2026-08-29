import 'package:one_one_app/one_one.dart';

/// Publishes the data the native Duo home-screen widget needs to render
/// small/medium/large layouts without waking Flutter: the current group
/// roster (with online presence) and which group was last active.
///
/// Android-only. On iOS this channel simply has no listener, so calls are
/// fire-and-forget no-ops there.
class DuoHomeWidgetSync {
  const DuoHomeWidgetSync._();

  static const MethodChannel _channel = MethodChannel('app.oneone/duo_widget');

  static Future<void> publish({
    required String userId,
    required String apiBaseUrl,
    required String accentKey,
    String? lastActiveGroupId,
    required List<DuoWidgetGroupSnapshot> groups,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final memberCount = groups.fold<int>(0, (sum, group) => sum + group.members.length);
      final photoCount = groups.fold<int>(
        0,
        (sum, group) =>
            sum + group.members.where((m) => (m.photoUrl?.isNotEmpty ?? false)).length,
      );
      final assetCount = groups.fold<int>(
        0,
        (sum, group) =>
            sum + group.members.where((m) => (m.avatarAsset?.isNotEmpty ?? false)).length,
      );
      debugPrint(
        '[DuoHomeWidgetSync] publish groups=${groups.length} '
        'members=$memberCount photos=$photoCount assets=$assetCount '
        'lastActive=${lastActiveGroupId ?? "none"} accent=$accentKey',
      );
      await _channel.invokeMethod('syncSnapshot', {
        'userId': userId,
        'apiBaseUrl': apiBaseUrl,
        'accentKey': accentKey,
        'lastActiveGroupId': lastActiveGroupId,
        'groups': groups.map((group) => group.toMap()).toList(),
      });
      debugPrint('[DuoHomeWidgetSync] publish OK');
    } catch (error, stack) {
      debugPrint('[DuoHomeWidgetSync] publish failed: $error\n$stack');
    }
  }
}

class DuoWidgetGroupSnapshot {
  const DuoWidgetGroupSnapshot({
    required this.groupId,
    required this.name,
    required this.members,
  });

  final String groupId;
  final String name;
  final List<DuoWidgetMemberSnapshot> members;

  Map<String, Object?> toMap() => {
    'groupId': groupId,
    'name': name,
    'members': members.map((member) => member.toMap()).toList(),
  };
}

class DuoWidgetMemberSnapshot {
  const DuoWidgetMemberSnapshot({
    required this.userId,
    required this.displayName,
    this.photoUrl,
    this.avatarAsset,
    this.online = false,
  });

  final String userId;
  final String displayName;
  final String? photoUrl;
  final String? avatarAsset;
  final bool online;

  Map<String, Object?> toMap() => {
    'userId': userId,
    'displayName': displayName,
    if (photoUrl != null && photoUrl!.isNotEmpty) 'photoUrl': photoUrl,
    if (avatarAsset != null && avatarAsset!.isNotEmpty) 'avatarAsset': avatarAsset,
    'online': online,
  };
}
