import 'package:one_one_app/one_one.dart';

class GroupRepository {
  GroupRepository({ApiClient? apiClient, FirebaseDatabase? database})
    : _apiClient = apiClient ?? ApiClient(),
      _database = database ?? AppDatabase.instance();

  final ApiClient _apiClient;
  final FirebaseDatabase _database;

  Future<GroupSummary> createGroup(String name) async {
    final response = await _apiClient.postJson('/v1/groups', {'name': name});
    final groupId = response['groupId'].toString();
    unawaited(AnalyticsService.logGroupCreated(groupId: groupId, memberCount: 1));
    unawaited(CrashlyticsService.log('group_created:$groupId'));
    final snapshot = await _database.ref('groups/$groupId').get();

    if (snapshot.value is Map<Object?, Object?>) {
      return GroupSummary.fromJson(
        groupId,
        snapshot.value! as Map<Object?, Object?>,
      );
    }

    return GroupSummary(
      groupId: groupId,
      name: name,
      ownerUserId: '',
      livekitRoomName: response['livekitRoomName'].toString(),
      groupState: 'active',
    );
  }

  Future<GroupInviteResult> createInvite(String groupId) async {
    final response = await _apiClient.postJson('/v1/groups/$groupId/invites', {
      'maxUses': 3,
      'expiresInHours': 72,
    });
    unawaited(AnalyticsService.logInviteCreated(groupId: groupId));
    return GroupInviteResult.fromJson(response);
  }

  Future<String> joinInvite(String inviteCode) async {
    final response = await _apiClient.postJson('/v1/invites/join', {
      'inviteCode': inviteCode,
    });
    final groupId = response['groupId'].toString();
    unawaited(AnalyticsService.logGroupJoined(groupId: groupId));
    unawaited(CrashlyticsService.log('group_joined:$groupId'));
    return groupId;
  }

  DatabaseReference userGroupsRef(String userId) {
    return _database.ref('userGroups/$userId');
  }

  /// Loads the caller's groups over the existing RTDB WebSocket.
  ///
  /// Falls back to `GET /v1/groups` once when the local inverse index may not
  /// exist yet (legacy accounts). After that, cold launches stay on RTDB.
  Future<List<GroupSummary>> loadGroupsForUser(String userId) async {
    final groups = await _loadGroupsFromRtdb(userId);
    if (groups.isNotEmpty) {
      unawaited(_markUserGroupsIndexReady(userId));
      return groups;
    }

    if (await _isUserGroupsIndexReady(userId)) {
      return const [];
    }

    try {
      final viaApi = await _loadGroupsFromApi();
      unawaited(_markUserGroupsIndexReady(userId));
      return viaApi;
    } catch (_) {
      // Prefer a successful empty RTDB read over a failed HTTP path.
      return const [];
    }
  }

  Future<List<GroupMemberSummary>> loadGroupMembers(String groupId) async {
    final membersSnap = await _database.ref('groupMembers/$groupId').get();
    if (membersSnap.value is! Map) return const [];

    final rawMembers = Map<Object?, Object?>.from(membersSnap.value! as Map);
    final activeEntries = <MapEntry<String, Map<Object?, Object?>>>[];

    for (final entry in rawMembers.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final member = Map<Object?, Object?>.from(raw);
      if ((member['memberState']?.toString() ?? 'active') != 'active') {
        continue;
      }
      final userId = entry.key.toString();
      if (userId.isEmpty) continue;
      activeEntries.add(MapEntry(userId, member));
    }

    if (activeEntries.isEmpty) return const [];

    final profiles = await Future.wait(
      activeEntries.map((entry) => _loadMemberProfile(entry.key)),
    );

    // Skip memberships whose users/{uid} record is gone or inactive.
    // That is the account-deletion signal — uninstall leaves users/{uid}
    // intact, so those members still appear (correctly) as away/unreachable.
    final members = <GroupMemberSummary>[];
    for (var i = 0; i < activeEntries.length; i++) {
      final profile = profiles[i];
      if (profile == null) continue;
      members.add(
        GroupMemberSummary(
          userId: activeEntries[i].key,
          displayName: profile.displayName,
          role: activeEntries[i].value['role']?.toString() ?? 'member',
          memberState: 'active',
          profilePhotoUrl: profile.profilePhotoUrl,
          profilePhotoBase64: profile.profilePhotoBase64,
          avatarAsset: profile.avatarAsset,
        ),
      );
    }
    return members;
  }

  Future<int> countActiveMembers(String groupId) async {
    final snapshot = await _database.ref('groupMembers/$groupId').get();

    if (snapshot.value is! Map<Object?, Object?>) {
      return 0;
    }

    var count = 0;
    for (final entry in (snapshot.value! as Map<Object?, Object?>).entries) {
      final raw = entry.value;
      if (raw is! Map<Object?, Object?>) continue;
      if ((raw['memberState']?.toString() ?? 'active') == 'active') {
        count++;
      }
    }

    return count;
  }

  Future<void> removeMember(String groupId, String memberUserId) async {
    await _apiClient.deleteJson(
      '/v1/groups/${Uri.encodeComponent(groupId)}/members/'
      '${Uri.encodeComponent(memberUserId)}',
    );
  }

  Future<void> leaveGroup(String groupId) async {
    await _apiClient.postJson(
      '/v1/groups/${Uri.encodeComponent(groupId)}/leave',
      const {},
    );
    unawaited(AnalyticsService.logGroupLeft(groupId: groupId));
    unawaited(CrashlyticsService.log('group_left:$groupId'));
  }

  Future<void> deleteGroup(String groupId) async {
    await _apiClient.deleteJson('/v1/groups/${Uri.encodeComponent(groupId)}');
  }

  Future<List<GroupSummary>> _loadGroupsFromRtdb(String userId) async {
    final indexSnap = await _database.ref('userGroups/$userId').get();
    if (indexSnap.value is! Map) return const [];

    final index = Map<Object?, Object?>.from(indexSnap.value! as Map);
    final groupIds = index.keys
        .map((key) => key.toString())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (groupIds.isEmpty) return const [];

    final groupSnaps = await Future.wait(
      groupIds.map((groupId) => _database.ref('groups/$groupId').get()),
    );

    final groups = <GroupSummary>[];
    for (var i = 0; i < groupIds.length; i++) {
      final snap = groupSnaps[i];
      if (snap.value is! Map) continue;
      final data = Map<Object?, Object?>.from(snap.value! as Map);
      if ((data['groupState']?.toString() ?? 'active') != 'active') {
        continue;
      }
      groups.add(GroupSummary.fromJson(groupIds[i], data));
    }
    return groups;
  }

  Future<List<GroupSummary>> _loadGroupsFromApi() async {
    final response = await _apiClient.getJson('/v1/groups');
    final rawGroups = response['groups'];
    if (rawGroups is! List) return const [];

    return rawGroups
        .whereType<Map>()
        .map((raw) {
          final groupId = raw['groupId']?.toString() ?? '';
          return GroupSummary.fromJson(groupId, raw.cast<Object?, Object?>());
        })
        .where((group) => group.groupId.isNotEmpty)
        .toList();
  }

  Future<_MemberProfileFields?> _loadMemberProfile(String userId) async {
    try {
      final snap = await _database.ref('users/$userId').get();
      if (snap.value is! Map) {
        // No users/{uid} → account was deleted. Do not treat as a live member.
        return null;
      }
      final data = Map<Object?, Object?>.from(snap.value! as Map);
      if ((data['accountState']?.toString() ?? 'active') != 'active') {
        return null;
      }
      final displayName = data['displayName']?.toString().trim();
      return _MemberProfileFields(
        displayName: (displayName == null || displayName.isEmpty)
            ? 'Friend'
            : displayName,
        profilePhotoUrl: data['profilePhotoUrl']?.toString(),
        profilePhotoBase64: data['profilePhotoBase64']?.toString(),
        avatarAsset: data['avatarAsset']?.toString(),
      );
    } catch (_) {
      // Transient read failures should not invent a "deleted" member; keep
      // them visible with a fallback name until a later refresh succeeds.
      return _MemberProfileFields(displayName: 'Friend');
    }
  }

  static String _userGroupsIndexReadyKey(String userId) =>
      'one_one_user_groups_index_ready_$userId';

  Future<bool> _isUserGroupsIndexReady(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_userGroupsIndexReadyKey(userId)) == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _markUserGroupsIndexReady(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_userGroupsIndexReadyKey(userId), true);
    } catch (_) {
      // Best-effort local cache; next launch may re-check via API once.
    }
  }
}

class _MemberProfileFields {
  const _MemberProfileFields({
    required this.displayName,
    this.profilePhotoUrl,
    this.profilePhotoBase64,
    this.avatarAsset,
  });

  final String displayName;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;
}
