import 'package:one_one_app/one_one.dart';

enum CallAudioUserMode { speaker, earpiece, muted }

// Speaker ↔ earpiece on tap. Long-press mutes. Headphones override display/route.
class CallAudioRouteController {
  CallAudioUserMode _userMode = CallAudioUserMode.speaker;
  CallAudioUserMode _preMuteMode = CallAudioUserMode.speaker;
  AudioOutputRoute _deviceRoute = AudioOutputRoute.speaker;
  bool _sessionActive = false;

  CallAudioUserMode get userMode => _userMode;

  AudioOutputRoute get deviceRoute => _deviceRoute;

  bool get sessionActive => _sessionActive;

  bool get muted => _userMode == CallAudioUserMode.muted;

  bool get headphonesConnected =>
      _deviceRoute == AudioOutputRoute.headset ||
      _deviceRoute == AudioOutputRoute.bluetooth;

  AudioOutputRoute get displayRoute {
    if (headphonesConnected) return _deviceRoute;
    return switch (_userMode) {
      CallAudioUserMode.earpiece => AudioOutputRoute.earpiece,
      CallAudioUserMode.speaker ||
      CallAudioUserMode.muted => AudioOutputRoute.speaker,
    };
  }

  AudioOutputGlyphKind get glyphKind =>
      resolveAudioOutputGlyph(route: displayRoute, muted: muted);

  /// Built-in speaker vs earpiece preference (survives headphone plug/unplug).
  bool get speakerOn => _userMode != CallAudioUserMode.earpiece;

  /// Value for LiveKit `setSpeakerOn`. Must be false while a headset or
  /// Bluetooth device is connected so the OS can own the route — otherwise
  /// speakerphone stays forced on and volume/output stay on the loudspeaker
  /// even though the call-bar glyph already shows headphones.
  bool get liveKitSpeakerOn => !headphonesConnected && speakerOn;

  String get preferenceName =>
      _userMode == CallAudioUserMode.earpiece ? 'earpiece' : 'speaker';

  bool get proximityEnabled =>
      _sessionActive &&
      _userMode == CallAudioUserMode.earpiece &&
      !headphonesConnected;

  void onSessionConnected() {
    _sessionActive = true;
    _userMode = CallAudioUserMode.speaker;
    _preMuteMode = CallAudioUserMode.speaker;
  }

  void onSessionEnded() {
    _sessionActive = false;
    _userMode = CallAudioUserMode.speaker;
    _preMuteMode = CallAudioUserMode.speaker;
  }

  void onDeviceRouteChanged(AudioOutputRoute route) {
    _deviceRoute = route;
  }

  CallAudioUserMode onTap() {
    if (_userMode == CallAudioUserMode.muted) {
      _userMode = CallAudioUserMode.speaker;
      return _userMode;
    }
    _userMode = _userMode == CallAudioUserMode.speaker
        ? CallAudioUserMode.earpiece
        : CallAudioUserMode.speaker;
    return _userMode;
  }

  CallAudioUserMode onLongPress() {
    if (_userMode == CallAudioUserMode.muted) {
      _userMode = CallAudioUserMode.speaker;
    } else {
      _userMode = CallAudioUserMode.muted;
    }
    return _userMode;
  }

  CallAudioUserMode toggleMute() {
    if (_userMode == CallAudioUserMode.muted) {
      _userMode = _preMuteMode;
    } else {
      _preMuteMode = _userMode;
      _userMode = CallAudioUserMode.muted;
    }
    return _userMode;
  }

  void applySettingsPreference(String preference) {
    if (_userMode == CallAudioUserMode.muted) return;
    _userMode = preference == 'earpiece'
        ? CallAudioUserMode.earpiece
        : CallAudioUserMode.speaker;
  }

  void restoreMode(CallAudioUserMode mode) {
    _userMode = mode;
  }
}
