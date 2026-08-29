import 'package:one_one_app/one_one.dart';

// 1. Overlay payload
// 2. Singleton that home calls setSession / clearSession on

class LiveSessionOverlayData {
  const LiveSessionOverlayData({
    required this.member,
    required this.groupName,
    required this.microphoneMuted,
    required this.onToggleMicrophone,
    required this.accentColor,
  });

  final GroupMemberSummary member;
  final String groupName;
  final bool microphoneMuted;
  final VoidCallback onToggleMicrophone;
  final Color accentColor;

  LiveSessionOverlayData copyWith({
    GroupMemberSummary? member,
    String? groupName,
    bool? microphoneMuted,
    VoidCallback? onToggleMicrophone,
    Color? accentColor,
  }) {
    return LiveSessionOverlayData(
      member: member ?? this.member,
      groupName: groupName ?? this.groupName,
      microphoneMuted: microphoneMuted ?? this.microphoneMuted,
      onToggleMicrophone: onToggleMicrophone ?? this.onToggleMicrophone,
      accentColor: accentColor ?? this.accentColor,
    );
  }
}

class LiveSessionOverlayController {
  LiveSessionOverlayController._();

  static final LiveSessionOverlayController instance =
      LiveSessionOverlayController._();

  final ValueNotifier<LiveSessionOverlayData?> state =
      ValueNotifier<LiveSessionOverlayData?>(null);

  void setSession(LiveSessionOverlayData data) => state.value = data;

  void updateSession(LiveSessionOverlayData data) {
    if (state.value != null) state.value = data;
  }

  void clearSession() => state.value = null;
}
