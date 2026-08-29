part of '../identity_home_screen.dart';

// 1. Live / talk / service-ready flags.
// 2. Display members and carousel items for the current frame.

mixin _IdentityHomeDerived on _IdentityHomeBase {
  @override
  bool get _isOnline => _onlineSession != null;

  @override
  bool get _microphoneEnabled =>
      _room?.localParticipant?.isMicrophoneEnabled() ?? false;

  /// LiveKit join, reconnect, or leave is in flight — the main button must
  /// show a loader instead of an empty middle state between online/offline.
  bool get _isSessionConnecting =>
      _nudgeActionInFlight ||
      _state == 'connecting' ||
      _state == 'reconnecting';

  @override
  bool get _isViewingActiveGroup =>
      _onlineSession?.groupId == _selectedGroup?.groupId;
  @override
  bool get _isCallMode => _connectionMode == MemberAvailability.callMode;

  /// True while this device is sending audio — latched call-mode mic or a
  /// leftover exclusive talk lock.
  @override
  bool get _isTransmitting =>
      _talkSession != null || (_isCallMode && !_microphoneMutedByUser);

  @override
  bool get _serviceReady =>
      groupHasServicePeer(members: _members, currentUserId: _session.userId);

  @override
  List<GroupMemberSummary> get _friends {
    return _members
        .where((member) => member.userId != _session.userId)
        .toList(growable: false);
  }

  @override
  List<GroupMemberSummary> get _displayMembers {
    return _displayMembersFrom(_members);
  }

  GroupMemberSummary get _pictureInPictureMember {
    final activeUserId = _speakingUserIds.firstOrNull ?? _session.userId;
    final activeMembers = _displayMembersFrom(
      _membersByGroupId[_onlineSession?.groupId] ?? const [],
    );
    for (final member in activeMembers) {
      if (member.userId == activeUserId) return member;
    }
    return GroupMemberSummary(
      userId: _session.userId,
      displayName: _session.user.displayName,
      role: 'member',
      memberState: 'active',
      profilePhotoUrl: _session.user.profilePhotoUrl,
      profilePhotoBase64: _session.user.profilePhotoBase64,
      avatarAsset: _session.user.avatarAsset,
    );
  }

  @override
  GroupMemberSummary get _localLiveMember => GroupMemberSummary(
    userId: _session.userId,
    displayName: _session.user.displayName,
    role: 'member',
    memberState: 'active',
    profilePhotoUrl: _session.user.profilePhotoUrl,
    profilePhotoBase64: _session.user.profilePhotoBase64,
    avatarAsset: _session.user.avatarAsset,
  );

  @override
  String get _activeLiveGroupName =>
      _groups
          .where((group) => group.groupId == _onlineSession?.groupId)
          .firstOrNull
          ?.name ??
      'Live conversation';

  List<GroupMemberSummary> _displayMembersFrom(
    List<GroupMemberSummary> members,
  ) {
    return members
        .map((member) {
          if (member.userId != _session.userId) return member;
          return GroupMemberSummary(
            userId: member.userId,
            displayName: _session.user.displayName,
            role: member.role,
            memberState: member.memberState,
            profilePhotoUrl: _session.user.profilePhotoUrl,
            profilePhotoBase64: _session.user.profilePhotoBase64,
            avatarAsset: _session.user.avatarAsset,
          );
        })
        .toList(growable: false);
  }

  ConnectionQuality get _effectiveLocalConnectionQuality {
    if (_connectivity.contains(ConnectivityResult.none)) {
      return ConnectionQuality.lost;
    }
    if (_localConnectionQuality != ConnectionQuality.unknown) {
      return _localConnectionQuality;
    }
    return _connectivity.isEmpty
        ? ConnectionQuality.unknown
        : ConnectionQuality.good;
  }

  List<_CarouselItem> get _carouselItems {
    final selfIsLive = _isOnline && (_state == 'live' || _state == 'talking');
    final selfAvailability = _isOnline
        ? MemberAvailability(
            desiredState: 'online',
            effectiveState: _state,
            canReceiveLiveAudio: selfIsLive,
          )
        : MemberAvailability.away;

    return [
      for (final group in _groups)
        _CarouselItem.group(
          group: group,
          displayName: _session.user.displayName,
          profilePhotoUrl: _session.user.profilePhotoUrl,
          profilePhotoBase64: _session.user.profilePhotoBase64,
          avatarAsset: _session.user.avatarAsset,
          availability: group.groupId == _onlineSession?.groupId
              ? selfAvailability
              : MemberAvailability.away,
          members: _displayMembersFrom(
            _membersByGroupId[group.groupId] ?? const [],
          ),
        ),
    ];
  }
}
