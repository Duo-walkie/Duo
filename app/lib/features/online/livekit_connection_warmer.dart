import 'package:one_one_app/one_one.dart';

// Prefetch token + warm Room/DNS before accept. Never calls Room.connect().
class LiveKitConnectionWarmer {
  LiveKitConnectionWarmer._();

  static final LiveKitConnectionWarmer instance = LiveKitConnectionWarmer._();

  bool _webRtcInitialized = false;
  Future<void>? _webRtcInitFuture;

  final Map<String, PreparedLiveKitToken> _tokens = {};

  Room? _warmRoom;
  bool? _warmRoomSpeakerOn;

  Future<void> ensureWebRtcInitialized() {
    if (_webRtcInitialized) return Future<void>.value();
    return _webRtcInitFuture ??= _initializeWebRtc();
  }

  Future<void> _initializeWebRtc() async {
    try {
      await LiveKitClient.initialize();
    } catch (_) {
      // Non-fatal. The SDK falls back to default initialization on first use.
    } finally {
      _webRtcInitialized = true;
      _webRtcInitFuture = null;
    }
  }

  PreparedLiveKitToken? takeToken(String groupId) {
    final prepared = _tokens[groupId];
    if (prepared == null) return null;
    if (!prepared.isUsableAt(_nowSeconds())) {
      _tokens.remove(groupId);
      return null;
    }
    _tokens.remove(groupId);
    return prepared;
  }

  // 1. Init WebRTC  2. Fetch token  3. Warm DNS/TLS (no join)
  Future<void> prefetch({
    required OnlineRepository repository,
    required IdentitySession identity,
    required GroupSummary group,
    required bool speakerOn,
  }) async {
    await ensureWebRtcInitialized();

    final PreparedLiveKitToken prepared;
    try {
      prepared = await repository.prepareToken(
        groupId: group.groupId,
        deviceId: identity.deviceId,
      );
    } catch (_) {
      // Best-effort. A failed prefetch must never surface to the user; the
      // real go-online path fetches a token synchronously if needed.
      return;
    }

    _tokens[group.groupId] = prepared;

    // Warm DNS + TLS to the LiveKit server without joining a room.
    final room = _buildWarmRoom(speakerOn: speakerOn);
    _warmRoom = room;
    _warmRoomSpeakerOn = speakerOn;
    try {
      await room.prepareConnection(
        prepared.response.serverUrl,
        prepared.response.token,
      );
    } catch (_) {
      // `prepareConnection` is best-effort and already swallows most errors.
    }
  }

  Room? takeWarmRoom({required bool speakerOn}) {
    final room = _warmRoom;
    if (room == null) return null;

    _warmRoom = null;
    final matchesSpeaker = _warmRoomSpeakerOn == speakerOn;
    _warmRoomSpeakerOn = null;

    if (!matchesSpeaker) {
      // Wrong audio route for this attempt — discard and let the caller build.
      unawaited(room.dispose());
      return null;
    }
    return room;
  }

  Room _buildWarmRoom({required bool speakerOn}) {
    final noiseFilter = LiveKitNoiseFilter();
    return Room(
      roomOptions: RoomOptions(
        adaptiveStream: false,
        dynacast: false,
        defaultAudioOutputOptions: AudioOutputOptions(speakerOn: speakerOn),
        defaultAudioCaptureOptions: AudioCaptureOptions(processor: noiseFilter),
      ),
    );
  }

  int _nowSeconds() =>
      DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
}
