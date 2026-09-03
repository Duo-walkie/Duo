import 'package:one_one_app/one_one.dart';

/// First-run welcome carousel shown before Google sign-in.
class WelcomeOnboardingScreen extends StatefulWidget {
  const WelcomeOnboardingScreen({super.key, required this.onFinished});

  static const seenPrefKey = 'one_one_welcome_onboarding_seen';

  final VoidCallback onFinished;

  static Future<bool> hasBeenSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(seenPrefKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(seenPrefKey, true);
    } catch (_) {}
  }

  @override
  State<WelcomeOnboardingScreen> createState() => _WelcomeOnboardingScreenState();
}

class _WelcomeOnboardingScreenState extends State<WelcomeOnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  static const _pages = [
    (
      asset: 'assets/Onboarding1.png',
      title: _OnboardingCopy.talkTitle,
      body: _OnboardingCopy.talkBody,
    ),
    (
      asset: 'assets/Onboarding3.png',
      title: _OnboardingCopy.notifyTitle,
      body: _OnboardingCopy.notifyBody,
    ),
    (
      asset: 'assets/Onboarding2.png',
      title: _OnboardingCopy.nudgeTitle,
      body: _OnboardingCopy.nudgeBody,
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _advance() async {
    if (_page < _pages.length - 1) {
      await _pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    await WelcomeOnboardingScreen.markSeen();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lastPage = _page == _pages.length - 1;
    return Scaffold(
      backgroundColor: BrandSplashScreen.backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 20.h),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: const WelcomeLanguageToggle(),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (index) => setState(() => _page = index),
                  itemBuilder: (context, index) {
                    final page = _pages[index];
                    return Column(
                      children: [
                        Expanded(
                          child: Image.asset(page.asset, fit: BoxFit.contain),
                        ),
                        SizedBox(height: 18.h),
                        Text(
                          page.title.of(l10n),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: const Color(0xff252a2e),
                            fontSize: 24.sp,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 10.h),
                        Text(
                          page.body.of(l10n),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: const Color.fromRGBO(37, 42, 46, 0.72),
                            fontSize: 14.sp,
                            height: 1.45,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              SizedBox(height: 18.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    Container(
                      width: i == _page ? 18.w : 8.w,
                      height: 8.w,
                      margin: EdgeInsets.symmetric(horizontal: 3.w),
                      decoration: BoxDecoration(
                        color: i == _page
                            ? const Color(0xff252a2e)
                            : const Color(0xff252a2e).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                ],
              ),
              SizedBox(height: 22.h),
              SizedBox(
                width: double.infinity,
                height: 54.h,
                child: FilledButton(
                  onPressed: () => unawaited(_advance()),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff252a2e),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27.r),
                    ),
                  ),
                  child: Text(
                    lastPage ? l10n.onboardingGetStarted : l10n.onboardingContinue,
                    style: TextStyle(
                      fontSize: 15.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _OnboardingCopy { talkTitle, talkBody, notifyTitle, notifyBody, nudgeTitle, nudgeBody }

extension on _OnboardingCopy {
  String of(AppLocalizations l10n) => switch (this) {
    _OnboardingCopy.talkTitle => l10n.onboardingPage1Title,
    _OnboardingCopy.talkBody => l10n.onboardingPage1Body,
    _OnboardingCopy.notifyTitle => l10n.onboardingPage2Title,
    _OnboardingCopy.notifyBody => l10n.onboardingPage2Body,
    _OnboardingCopy.nudgeTitle => l10n.onboardingPage3Title,
    _OnboardingCopy.nudgeBody => l10n.onboardingPage3Body,
  };
}
