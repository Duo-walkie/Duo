import 'package:one_one_app/one_one.dart';

// ---------------------------------------------------------------------------
// Enum — pre-release home screen backdrop variants for UI evaluation.
// Remove before next public release or gate behind compile-time flag.
// ---------------------------------------------------------------------------

enum HomeVisualVariant {
  /// Current production look — blurred member collage.
  defaultLook(
    label: 'Default (current)',
    subtitle: 'Current home screen — member collage backdrop.',
    assetPath: null,
  ),

  /// Same layout and controls, doodle wallpaper 1 behind everything.
  screen1(
    label: 'Home screen 1',
    subtitle: 'Doodle backdrop. Same layout, top and bottom contrast scrims.',
    assetPath: 'assets/home_bg_images/home_bg_screen1.png',
  ),

  /// Same layout and controls, doodle wallpaper 2 behind everything.
  screen2(
    label: 'Home screen 2',
    subtitle: 'Alternate doodle backdrop. Same layout and controls.',
    assetPath: 'assets/home_bg_images/home_bg_screen2.png',
  );

  const HomeVisualVariant({
    required this.label,
    required this.subtitle,
    required this.assetPath,
  });

  final String label;
  final String subtitle;

  /// Bundled wallpaper for doodle variants. Null for the production look.
  final String? assetPath;

  bool get usesDoodleBackdrop => assetPath != null;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Manages the active [HomeVisualVariant] and the testing-section unlock
/// state. Persisted to SharedPreferences so the team's selection survives
/// app restarts during evaluation.
///
/// The testing section in Settings is hidden until [unlockTesting] is called
/// (tap "Settings" title 7 times rapidly). Remove this controller and its
/// references before the next public release.
class HomeVisualVariantController {
  HomeVisualVariantController._();

  static const _prefKeyVariant = 'home_visual_variant';
  static const _prefKeyUnlocked = 'home_visual_testing_unlocked';

  /// Whether the hidden testing section has been unlocked by the team.
  static final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);

  /// The currently active home screen visual variant.
  static final ValueNotifier<HomeVisualVariant> current =
      ValueNotifier<HomeVisualVariant>(HomeVisualVariant.defaultLook);

  /// Load persisted state. Call once on settings / home screen init.
  static Future<void> ensureLoaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKeyVariant);
      if (raw != null) {
        final match = HomeVisualVariant.values
            .where((v) => v.name == raw)
            .firstOrNull;
        if (match != null) current.value = match;
      }
      unlocked.value = prefs.getBool(_prefKeyUnlocked) ?? false;
    } catch (_) {
      // Best-effort; defaults remain if prefs fail.
    }
  }

  /// Persist and apply a variant selection.
  static Future<void> setVariant(HomeVisualVariant variant) async {
    current.value = variant;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyVariant, variant.name);
    } catch (_) {}
  }

  /// Unlock the testing section. Called after the hidden tap sequence.
  static Future<void> unlockTesting() async {
    unlocked.value = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyUnlocked, true);
    } catch (_) {}
  }
}
