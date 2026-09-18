import 'package:one_one_app/one_one.dart';

/// Celebratory floating snackbar after a successful invite-link join.
void showInviteJoinedSnackBar(BuildContext context) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final l10n = context.l10n;

  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xff141414),
        elevation: 10,
        duration: const Duration(seconds: 7),
        margin: EdgeInsets.fromLTRB(14.w, 0, 14.w, 18.h),
        padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 14.h),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.r),
          side: const BorderSide(color: Color(0xffF8BE03), width: 1.2),
        ),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42.w,
              height: 42.w,
              decoration: BoxDecoration(
                color: const Color(0xffF8BE03).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12.r),
              ),
              alignment: Alignment.center,
              child: Image.asset(
                'assets/logo.png',
                height: 26.h,
                fit: BoxFit.contain,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.inviteJoinedTitle,
                    style: TextStyle(
                      color: const Color(0xffF8BE03),
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    l10n.inviteJoinedBody,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.80),
                      fontSize: 12.5.sp,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
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

void showInviteJoinErrorSnackBar(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final cleaned = message.trim();
  if (cleaned.isEmpty) return;

  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xff1a1212),
        elevation: 10,
        duration: const Duration(seconds: 6),
        margin: EdgeInsets.fromLTRB(14.w, 0, 14.w, 18.h),
        padding: EdgeInsets.fromLTRB(14.w, 14.h, 14.w, 14.h),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.r),
          side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.55)),
        ),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42.w,
              height: 42.w,
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12.r),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.link_off_rounded,
                color: Colors.redAccent.shade100,
                size: 22.sp,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Couldn’t join invite',
                    style: TextStyle(
                      color: Colors.redAccent.shade100,
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    cleaned,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontSize: 12.5.sp,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
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
