import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  group('CallAudioRouteController', () {
    test('connect defaults to speaker unmuted', () {
      final c = CallAudioRouteController()
        ..applySettingsPreference('earpiece')
        ..onSessionConnected();
      expect(c.userMode, CallAudioUserMode.speaker);
      expect(c.muted, isFalse);
      expect(c.speakerOn, isTrue);
      expect(c.proximityEnabled, isFalse);
      expect(c.glyphKind, AudioOutputGlyphKind.speaker);
    });

    test('tap cycles speaker → earpiece → speaker', () {
      final c = CallAudioRouteController()..onSessionConnected();
      expect(c.onTap(), CallAudioUserMode.earpiece);
      expect(c.proximityEnabled, isTrue);
      expect(c.glyphKind, AudioOutputGlyphKind.earpiece);
      expect(c.onTap(), CallAudioUserMode.speaker);
      expect(c.proximityEnabled, isFalse);
    });

    test('long-press mutes; tap after mute returns to speaker', () {
      final c = CallAudioRouteController()..onSessionConnected();
      c.onTap(); // earpiece
      expect(c.onLongPress(), CallAudioUserMode.muted);
      expect(c.glyphKind, AudioOutputGlyphKind.muted);
      expect(c.proximityEnabled, isFalse);
      expect(c.onTap(), CallAudioUserMode.speaker);
      expect(c.muted, isFalse);
      expect(c.speakerOn, isTrue);
    });

    test('headphones override display and disable proximity', () {
      final c = CallAudioRouteController()..onSessionConnected();
      c.onTap(); // earpiece
      expect(c.proximityEnabled, isTrue);
      c.onDeviceRouteChanged(AudioOutputRoute.bluetooth);
      expect(c.headphonesConnected, isTrue);
      expect(c.displayRoute, AudioOutputRoute.bluetooth);
      expect(c.glyphKind, AudioOutputGlyphKind.headset);
      expect(c.proximityEnabled, isFalse);
      expect(c.userMode, CallAudioUserMode.earpiece);
      // Preference stays earpiece, but LiveKit must not force speakerphone.
      expect(c.speakerOn, isFalse);
      expect(c.liveKitSpeakerOn, isFalse);

      c.onDeviceRouteChanged(AudioOutputRoute.speaker);
      expect(c.headphonesConnected, isFalse);
      expect(c.displayRoute, AudioOutputRoute.earpiece);
      expect(c.proximityEnabled, isTrue);
    });

    test('headphones release LiveKit speakerphone while preference stays speaker',
        () {
      final c = CallAudioRouteController()..onSessionConnected();
      expect(c.speakerOn, isTrue);
      expect(c.liveKitSpeakerOn, isTrue);

      c.onDeviceRouteChanged(AudioOutputRoute.headset);
      expect(c.headphonesConnected, isTrue);
      expect(c.speakerOn, isTrue);
      expect(c.liveKitSpeakerOn, isFalse);
      expect(c.glyphKind, AudioOutputGlyphKind.headset);

      c.onDeviceRouteChanged(AudioOutputRoute.speaker);
      expect(c.liveKitSpeakerOn, isTrue);
      expect(c.glyphKind, AudioOutputGlyphKind.speaker);
    });

    test('device route changes never flip mute or user mode', () {
      final c = CallAudioRouteController()..onSessionConnected();
      c.onLongPress();
      c.onDeviceRouteChanged(AudioOutputRoute.earpiece);
      expect(c.userMode, CallAudioUserMode.muted);
      c.onDeviceRouteChanged(AudioOutputRoute.speaker);
      expect(c.userMode, CallAudioUserMode.muted);
    });

    test('session end clears proximity eligibility', () {
      final c = CallAudioRouteController()..onSessionConnected();
      c.onTap();
      expect(c.proximityEnabled, isTrue);
      c.onSessionEnded();
      expect(c.proximityEnabled, isFalse);
      expect(c.userMode, CallAudioUserMode.speaker);
    });
  });
}
