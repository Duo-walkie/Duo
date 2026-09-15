import 'package:one_one_app/one_one.dart';

/// Formerly the dark sticker welcome preview.
///
/// The redesign now lives in [GoogleAuthScreen]. This entry point remains
/// so Settings can still open the pre-redesign light welcome for comparison.
@Deprecated(
  'Redesign is live in GoogleAuthScreen. Use DeprecatedGoogleAuthScreen '
  'to view the old light welcome.',
)
class WelcomeRedesignPreviewScreen extends StatelessWidget {
  @Deprecated(
    'Redesign is live in GoogleAuthScreen. Use DeprecatedGoogleAuthScreen '
    'to view the old light welcome.',
  )
  const WelcomeRedesignPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use_from_same_package
    return const DeprecatedGoogleAuthScreen();
  }
}
