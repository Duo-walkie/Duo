class MemberAvailability {
  const MemberAvailability({
    required this.desiredState,
    required this.effectiveState,
    required this.canReceiveLiveAudio,
    this.staleAfterAt,
    this.connectionMode = walkieTalkieMode,
  });

  /// Default: mic stays off until the user taps the main button.
  static const String walkieTalkieMode = 'walkieTalkie';

  /// Latched-on mic after the user taps the main button. Independent per
  /// member — voices overlap when more than one person has tapped.
  static const String callMode = 'call';

  static const MemberAvailability away = MemberAvailability(
    desiredState: 'away',
    effectiveState: 'away',
    canReceiveLiveAudio: false,
  );

  final String desiredState;
  final String effectiveState;
  final bool canReceiveLiveAudio;
  final int? staleAfterAt;

  /// Per-user connection style: [walkieTalkieMode] (mic off until tapped)
  /// or [callMode] (latched-on mic). This is independent per member — it is
  /// never a group-wide setting.
  final String connectionMode;

  factory MemberAvailability.fromJson(Map<Object?, Object?> data) {
    return MemberAvailability(
      desiredState: data['desiredState']?.toString() ?? 'away',
      effectiveState: data['effectiveState']?.toString() ?? 'away',
      canReceiveLiveAudio: data['canReceiveLiveAudio'] == true,
      staleAfterAt: _readInt(data['staleAfterAt']),
      connectionMode: data['connectionMode']?.toString() ?? walkieTalkieMode,
    );
  }

  bool get isCallMode => connectionMode == callMode;

  bool get isLive => isLiveAt(
    DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
  );

  bool get isTalking {
    if (!isLive) return false;
    return effectiveState == 'talking';
  }

  /// True while a member has an active voice session — including the brief
  /// `connecting` handshake before audio actually flows. Unlike [isLive],
  /// this does not require [canReceiveLiveAudio] yet, so it can be used to
  /// detect "someone is already joining/in a session" a moment earlier.
  bool get isInVoiceSession => isInVoiceSessionAt(
    DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
  );

  bool isInVoiceSessionAt(int epochSeconds) {
    final expiresAt = staleAfterAt;
    if (expiresAt != null && expiresAt <= epochSeconds) return false;
    if (desiredState != 'online') return false;

    return effectiveState == 'connecting' ||
        effectiveState == 'live' ||
        effectiveState == 'talking' ||
        effectiveState == 'listening' ||
        effectiveState == 'connected';
  }

  bool isLiveAt(int epochSeconds) {
    final expiresAt = staleAfterAt;
    if (expiresAt != null && expiresAt <= epochSeconds) return false;
    if (desiredState != 'online' || !canReceiveLiveAudio) return false;

    return effectiveState == 'live' ||
        effectiveState == 'talking' ||
        effectiveState == 'listening' ||
        effectiveState == 'connected';
  }

  String get label {
    return switch (effectiveState) {
      'talking' => 'Talking',
      'live' => 'Live',
      'connected' => 'Live',
      'connecting' => 'Connecting',
      'listening' => 'Listening',
      'away' => 'Away',
      _ => desiredState == 'online' ? 'Online' : 'Away',
    };
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }
}
