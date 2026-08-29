class NudgeTarget {
  const NudgeTarget.allFriends()
    : targetScope = 'all_friends',
      targetUserId = null,
      targetUserIds = const [];

  const NudgeTarget.singleFriend(this.targetUserId)
    : targetScope = 'single_friend',
      targetUserIds = const [];

  NudgeTarget.selectedFriends(List<String> userIds)
    : targetScope = userIds.length == 1 ? 'single_friend' : 'selected_friends',
      targetUserId = userIds.length == 1 ? userIds.first : null,
      targetUserIds = userIds.length == 1
          ? const []
          : List<String>.unmodifiable(userIds);

  final String targetScope;
  final String? targetUserId;
  final List<String> targetUserIds;

  Map<String, Object?> get json {
    final result = <String, Object?>{'targetScope': targetScope};
    final userId = targetUserId;
    if (userId != null) result['targetUserId'] = userId;
    if (targetUserIds.isNotEmpty) {
      result['targetUserIds'] = targetUserIds;
    }
    return result;
  }

  Map<String, String> get query {
    final result = <String, String>{'targetScope': targetScope};
    final userId = targetUserId;
    if (userId != null) result['targetUserId'] = userId;
    if (targetUserIds.isNotEmpty) {
      result['targetUserIds'] = targetUserIds.join(',');
    }
    return result;
  }
}
