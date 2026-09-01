import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

/// WhatsApp-style swipe-up-to-cancel while holding a voice-record button.
///
/// Owns pointer routing (so the finger can leave the button), slide progress,
/// cancel-armed state, and the trash/chevron hint UI. Recording start/stop and
/// upload stay in the host screen — this only decides **send vs discard** on
/// release (including after the mic has already stopped at the duration cap).
///
/// Usage:
/// ```dart
/// final cancel = VoiceRecordSwipeCancel()..addListener(() => setState(() {}));
///
/// // onPointerDown:
/// cancel.begin(
///   pointer: event.pointer,
///   startDy: event.position.dy,
///   onHoldEnded: (send) => finishRecording(send: send),
/// );
///
/// // in dispose:
/// cancel.dispose();
/// ```
class VoiceRecordSwipeCancel extends ChangeNotifier {
  VoiceRecordSwipeCancel({
    this.thresholdPx = 72,
    this.deleteColor = const Color(0xffff4040),
  });

  /// Vertical travel (px) required to arm cancel.
  final double thresholdPx;

  /// Accent used when cancel is armed (button + hint).
  final Color deleteColor;

  int? _pointerId;
  double _startDy = 0;
  double _slideUpPx = 0;
  bool _armed = false;
  bool _active = false;
  void Function(bool send)? _onHoldEnded;

  /// True from [begin] until release/cancel/reset.
  bool get isActive => _active;

  /// True once the finger has swiped up past [thresholdPx].
  bool get isArmed => _armed;

  /// Current upward travel in logical pixels (clamped).
  double get slideUpPx => _slideUpPx;

  /// 0 = no slide, 1 = cancel threshold reached (may exceed slightly).
  double get progress => (_slideUpPx / thresholdPx).clamp(0.0, 1.0);

  /// Convenience: release should send unless cancel is armed.
  bool get shouldSendOnRelease => !_armed;

  /// Pixel offset to lift the held button toward the trash target.
  Offset get buttonLiftOffset => Offset(0, -_slideUpPx * 0.28);

  /// Status copy while recording (or capped-and-still-holding).
  String recordingStatusMessage({
    required bool isRecording,
    bool capped = false,
  }) {
    if (!isRecording) return '';
    if (_armed) return 'Release to delete';
    if (capped) return 'Release to send\u2026 swipe up to cancel';
    return 'Recording\u2026 swipe up to cancel';
  }

  /// Start tracking a hold. [onHoldEnded] is invoked once with `true` to send
  /// or `false` to discard. Safe to call again — previous tracking is cleared.
  void begin({
    required int pointer,
    required double startDy,
    required void Function(bool send) onHoldEnded,
  }) {
    _detachPointerRoute();
    _pointerId = pointer;
    _startDy = startDy;
    _slideUpPx = 0;
    _armed = false;
    _active = true;
    _onHoldEnded = onHoldEnded;
    GestureBinding.instance.pointerRouter.addRoute(pointer, _onPointerEvent);
    notifyListeners();
  }

  /// Clear slide/armed UI without ending a hold (e.g. after record finish).
  void reset() {
    _detachPointerRoute();
    _slideUpPx = 0;
    _armed = false;
    _active = false;
    _onHoldEnded = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _detachPointerRoute();
    _onHoldEnded = null;
    super.dispose();
  }

  void _detachPointerRoute() {
    final id = _pointerId;
    if (id == null) return;
    _pointerId = null;
    GestureBinding.instance.pointerRouter.removeRoute(id, _onPointerEvent);
  }

  void _onPointerEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _updateSlide(event.position.dy);
      return;
    }
    if (event is PointerUpEvent) {
      _endHold(send: !_armed);
      return;
    }
    if (event is PointerCancelEvent) {
      _endHold(send: false);
    }
  }

  void _updateSlide(double currentDy) {
    final slideUp = (_startDy - currentDy).clamp(0.0, thresholdPx * 1.4);
    final armed = slideUp >= thresholdPx;
    if (armed == _armed && slideUp == _slideUpPx) return;
    if (armed != _armed) {
      unawaited(HapticFeedback.mediumImpact());
    }
    _slideUpPx = slideUp;
    _armed = armed;
    notifyListeners();
  }

  void _endHold({required bool send}) {
    if (!_active) return;
    _detachPointerRoute();
    _slideUpPx = 0;
    _armed = false;
    _active = false;
    final callback = _onHoldEnded;
    _onHoldEnded = null;
    notifyListeners();
    callback?.call(send);
  }
}

/// Trash + chevron target shown above the mic while holding.
class VoiceRecordSwipeCancelHint extends StatefulWidget {
  const VoiceRecordSwipeCancelHint({
    super.key,
    required this.progress,
    required this.armed,
    required this.color,
  });

  /// 0 = no slide, 1 = cancel threshold reached.
  final double progress;
  final bool armed;
  final Color color;

  @override
  State<VoiceRecordSwipeCancelHint> createState() =>
      _VoiceRecordSwipeCancelHintState();
}

class _VoiceRecordSwipeCancelHintState extends State<VoiceRecordSwipeCancelHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.progress.clamp(0.0, 1.0);
    final color = Color.lerp(Colors.white38, widget.color, t)!;
    final scale = 0.92 + t * 0.32;

    return AnimatedBuilder(
      animation: _bob,
      builder: (context, _) {
        final bob = widget.armed ? 0.0 : -5.h * _bob.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.scale(
              scale: scale,
              child: Container(
                width: 36.r,
                height: 36.r,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.12 + t * 0.28),
                  border: Border.all(color: color, width: 1.4),
                ),
                child: Icon(LucideIcons.trash2, size: 18.sp, color: color),
              ),
            ),
            Transform.translate(
              offset: Offset(0, bob),
              child: Icon(
                LucideIcons.chevronUp,
                size: 18.sp,
                color: widget.armed ? widget.color : Colors.white38,
              ),
            ),
          ],
        );
      },
    );
  }
}
