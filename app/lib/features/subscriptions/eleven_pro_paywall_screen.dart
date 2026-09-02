import 'package:one_one_app/one_one.dart';

/// Brand yellow used on auth/onboarding — not the user accent color.
const Color _kBrandYellow = Color(0xffF8BE03);

/// In-app Duo Pro paywall matching Settings UI surfaces.
///
/// Returns `true` from [open] when the user purchases or restores Pro access.
class ElevenProPaywallScreen extends StatefulWidget {
  const ElevenProPaywallScreen({super.key});

  static Future<bool> open(BuildContext context) async {
    final result = await Navigator.of(context).push<bool>(
      PageRouteBuilder<bool>(
        opaque: true,
        barrierColor: const Color(0xff101010),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return const AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: ColoredBox(
              color: Color(0xff101010),
              child: ElevenProPaywallScreen(),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.08),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    return result ?? false;
  }

  @override
  State<ElevenProPaywallScreen> createState() => _ElevenProPaywallScreenState();
}

class _ElevenProPaywallScreenState extends State<ElevenProPaywallScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _alreadyPro = false;
  String? _error;
  List<Package> _packages = const [];
  Package? _selected;

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService.logScreenView(screenName: 'paywall'));
    unawaited(AnalyticsService.logPaywallViewed(source: 'settings'));
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rc = await RevenueCatService.initialize();
      final entitled = await rc.isEntitledToPro();
      if (entitled) {
        if (!mounted) return;
        setState(() {
          _alreadyPro = true;
          _loading = false;
        });
        return;
      }

      final offerings = await rc.getOfferings();
      final current = offerings.current;
      final packages = current?.availablePackages ?? const <Package>[];
      if (packages.isEmpty) {
        throw const RevenueCatException(
          'Subscription options are not available yet. Try again later.',
        );
      }

      Package preferred = packages.first;
      for (final package in packages) {
        if (package.packageType == PackageType.monthly) {
          preferred = package;
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        _packages = packages;
        _selected = preferred;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is RevenueCatException
            ? error.message
            : 'Could not load subscription options.';
      });
    }
  }

  Future<void> _purchase() async {
    final package = _selected;
    if (package == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    unawaited(
      AnalyticsService.logButtonClick(
        buttonName: 'purchase',
        screenName: 'paywall',
      ),
    );
    unawaited(
      AnalyticsService.logPurchaseStarted(
        packageId: package.storeProduct.identifier,
      ),
    );
    try {
      final rc = await RevenueCatService.initialize();
      final info = await rc.purchasePackage(package);
      final entitled =
          info.entitlements.active.containsKey(AppConfig.proEntitlementId);
      if (!mounted) return;
      if (entitled) {
        final entitlement =
            info.entitlements.active[AppConfig.proEntitlementId];
        final isTrial = entitlement?.periodType == PeriodType.trial ||
            entitlement?.periodType == PeriodType.intro;
        if (isTrial) {
          unawaited(
            AnalyticsService.logTrialStarted(
              packageId: package.storeProduct.identifier,
            ),
          );
        }
        unawaited(
          AnalyticsService.logPurchaseCompleted(
            packageId: package.storeProduct.identifier,
          ),
        );
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _busy = false;
        _error = 'Purchase completed, but Pro access is not active yet.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (error is RevenueCatException &&
            error.message == 'Purchase was cancelled.') {
          _error = null;
        } else {
          _error = error is RevenueCatException
              ? error.message
              : 'Purchase failed. Please try again.';
        }
      });
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rc = await RevenueCatService.initialize();
      final info = await rc.restorePurchases();
      final entitled =
          info.entitlements.active.containsKey(AppConfig.proEntitlementId);
      if (!mounted) return;
      if (entitled) {
        unawaited(
          AnalyticsService.logPurchaseCompleted(
            packageId: _selected?.storeProduct.identifier,
            method: 'restore',
          ),
        );
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _busy = false;
        _error = 'No active Duo Pro subscription found to restore.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is RevenueCatException
            ? error.message
            : 'Could not restore purchases.';
      });
    }
  }

  String _titleFor(Package package) {
    switch (package.packageType) {
      case PackageType.weekly:
        return 'Weekly';
      case PackageType.monthly:
        return 'Monthly';
      case PackageType.twoMonth:
        return '2 months';
      case PackageType.threeMonth:
        return '3 months';
      case PackageType.sixMonth:
        return '6 months';
      case PackageType.annual:
        return 'Yearly';
      case PackageType.lifetime:
        return 'Lifetime';
      case PackageType.custom:
      case PackageType.unknown:
        return package.storeProduct.title.isNotEmpty
            ? package.storeProduct.title
            : 'Plan';
    }
  }

  String _subtitleFor(Package package) {
    switch (package.packageType) {
      case PackageType.weekly:
        return 'Billed every week';
      case PackageType.monthly:
        return 'Billed every month';
      case PackageType.twoMonth:
        return 'Billed every 2 months';
      case PackageType.threeMonth:
        return 'Billed every 3 months';
      case PackageType.sixMonth:
        return 'Billed every 6 months';
      case PackageType.annual:
        return 'Billed once a year';
      case PackageType.lifetime:
        return 'One-time purchase';
      case PackageType.custom:
      case PackageType.unknown:
        return package.storeProduct.description;
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = _kBrandYellow;

    return Scaffold(
      backgroundColor: const Color(0xff101010),
      appBar: AppBar(
        backgroundColor: const Color(0xff101010),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text('Duo Pro'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              )
            : _alreadyPro
                ? _AlreadyProBody(
                    accent: accent,
                    onDone: () => Navigator.of(context).pop(false),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                          children: [
                            const _PaywallHero(),
                            const SizedBox(height: 28),
                            const _FeatureList(),
                            const SizedBox(height: 24),
                            if (_error != null) ...[
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xffff8a80),
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (_packages.isEmpty)
                                Center(
                                  child: TextButton(
                                    onPressed: _busy ? null : _load,
                                    child: const Text('Try again'),
                                  ),
                                ),
                            ],
                            if (_packages.isNotEmpty) ...[
                              const Text(
                                'CHOOSE A PLAN',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0,
                                ),
                              ),
                              const SizedBox(height: 12),
                              for (final package in _packages) ...[
                                _PlanTile(
                                  package: package,
                                  title: _titleFor(package),
                                  subtitle: _subtitleFor(package),
                                  selected: identical(package, _selected) ||
                                      package.identifier ==
                                          _selected?.identifier,
                                  accent: accent,
                                  enabled: !_busy,
                                  onTap: () =>
                                      setState(() => _selected = package),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ],
                          ],
                        ),
                      ),
                      if (_packages.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                          child: Column(
                            children: [
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                  onPressed: _busy || _selected == null
                                      ? null
                                      : _purchase,
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size.fromHeight(54),
                                    backgroundColor: accent,
                                    foregroundColor: Colors.black,
                                    disabledBackgroundColor:
                                        accent.withValues(alpha: 0.35),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: _busy
                                      ? const SizedBox.square(
                                          dimension: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            color: Colors.black,
                                          ),
                                        )
                                      : Text(
                                          _selected == null
                                              ? 'Continue'
                                              : 'Continue · ${_selected!.storeProduct.priceString}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextButton(
                                onPressed: _busy ? null : _restore,
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                ),
                                child: const Text('Restore purchases'),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Prices are set by the App Store or Google Play. '
                                'Duo Pro is currently in beta.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _PaywallHero extends StatelessWidget {
  const _PaywallHero();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff1b1b1b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
        child: Column(
          children: [
            Image.asset(
              'assets/logo-new.png',
              width: 112,
              height: 112,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Duo Pro',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
                const _BetaBadge(),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Get early access while Duo Pro is in beta. Plans and perks may change as we polish the experience.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white60,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BetaBadge extends StatelessWidget {
  const _BetaBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xffffb020).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xffffb020).withValues(alpha: 0.55),
        ),
      ),
      child: const Text(
        'BETA',
        style: TextStyle(
          color: Color(0xffffb020),
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList();

  static const _items = <(IconData, String, String)>[
    (
      Icons.bolt_outlined,
      'Early Pro access',
      'Unlock Duo Pro features as they roll out during beta.',
    ),
    (
      Icons.support_agent_outlined,
      'Talk to Team Duo',
      'Reach us directly for billing or beta feedback.',
    ),
    (
      Icons.autorenew_rounded,
      'Flexible subscription',
      'Change or cancel anytime from Manage Subscription.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff1b1b1b),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
        child: Column(
          children: [
            for (var i = 0; i < _items.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_items[i].$1, color: Colors.white70, size: 22),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _items[i].$2,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _items[i].$3,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (i < _items.length - 1)
                Divider(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.09),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.package,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  final Package package;
  final String title;
  final String subtitle;
  final bool selected;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xff1b1b1b),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.9)
                  : Colors.white.withValues(alpha: 0.09),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? accent : Colors.white38,
                    width: 2,
                  ),
                  color: selected ? accent : Colors.transparent,
                ),
                child: selected
                    ? const Icon(Icons.check_rounded, size: 14, color: Colors.black)
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                package.storeProduct.priceString,
                style: TextStyle(
                  color: selected ? accent : Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlreadyProBody extends StatelessWidget {
  const _AlreadyProBody({
    required this.accent,
    required this.onDone,
  });

  final Color accent;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        children: [
          const Spacer(),
          Image.asset(
            'assets/logo-new.png',
            width: 120,
            height: 120,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 20),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'You\'re on Duo Pro',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: 10),
              _BetaBadge(),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Thanks for testing Duo Pro while it\'s in beta. Manage your plan or contact Team Duo anytime from Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, height: 1.45),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onDone,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                backgroundColor: accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Done',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
