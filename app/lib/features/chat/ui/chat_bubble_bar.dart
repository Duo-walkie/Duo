import 'package:one_one_app/one_one.dart';

import '../../identity/ui/legal_document_content.dart';

/// Bottom messages bar whose content depends on group online state:
/// - All offline: predefined text chips + pinned keyboard.
/// - Anyone online: emoji row (+ more) + pinned keyboard.
///
/// The keyboard icon is always outside the scrollable list so it stays
/// visible without horizontal scrolling.
class ChatBubbleBar extends StatefulWidget {
  const ChatBubbleBar({
    super.key,
    required this.accent,
    required this.anyMemberOnline,
    required this.onSend,
    required this.onEmojiSelected,
    this.enabled = true,
  });

  final Color accent;

  /// When true (mixed or all online), text chips are replaced by emojis.
  final bool anyMemberOnline;

  /// When false, the bar is visible but grayed out and non-interactive
  /// (e.g. waiting for an invitee to join the group).
  final bool enabled;

  /// Sends a preset or custom message. Rethrows on failure so the bar can
  /// surface a brief inline error instead of silently swallowing it.
  final Future<void> Function(String text) onSend;

  /// Fires when a fixed-row emoji or one from the "more emojis" picker is
  /// chosen. Wired by the host to the existing emoji-burst path.
  final ValueChanged<String> onEmojiSelected;

  static const List<String> quickEmojis = [
    '😂',
    '❤️',
    '👍',
    '🔥',
    '👏',
    '😮',
    '🎉',
    '👀',
    '💯',
    '🙏',
  ];

  /// Expanded set shown in the "more emojis" sheet.
  static const List<String> moreEmojis = [
    '😂',
    '🤣',
    '😊',
    '😍',
    '🥰',
    '😘',
    '😎',
    '🤔',
    '😮',
    '😢',
    '😭',
    '😡',
    '👍',
    '👎',
    '👏',
    '🙌',
    '🙏',
    '💪',
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🔥',
    '⭐',
    '✨',
    '🎉',
    '🎊',
    '👀',
    '💯',
    '✅',
    '❌',
    '👋',
    '🤝',
    '💤',
    '🚀',
    '🎯',
    '💡',
  ];

  @override
  State<ChatBubbleBar> createState() => _ChatBubbleBarState();
}

class _ChatBubbleBarState extends State<ChatBubbleBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _composing = false;
  bool _sending = false;

  @override
  void didUpdateWidget(covariant ChatBubbleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anyMemberOnline != widget.anyMemberOnline) {
      // Online swaps presets → emoji row; leave the composer if it was open
      // so the emoji / "more" controls aren't hidden behind the text field.
      if (widget.anyMemberOnline && _composing) {
        _closeComposer();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openComposer() {
    setState(() => _composing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _closeComposer() {
    _controller.clear();
    _focusNode.unfocus();
    setState(() => _composing = false);
  }

  Future<void> _sendPreset(String text) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
    } catch (_) {
      // Best-effort UX: the row stays usable, no blocking error dialog for
      // a one-tap ephemeral message.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendCustom() async {
    final sanitized = ChatMessageRepository.sanitize(_controller.text);
    if (sanitized == null || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(sanitized);
      if (mounted) _controller.clear();
    } catch (_) {
      // See _sendPreset.
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _openMoreEmojis() async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff161616),
      // Without this, a non-scroll-controlled sheet caps its own height to
      // a fraction of the screen — on shorter screens (or while live in a
      // channel with the header chrome already visible) the fixed handle +
      // title + grid could exceed that cap and overflow underneath it even
      // though the grid itself was wrapped in a scroll view. Scroll-
      // controlling the sheet and scrolling the *entire* body (below) fixes
      // that for any screen size.
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20.r)),
      ),
      builder: (sheetContext) {
        final l10n = sheetContext.l10n;
        final maxSheetHeight =
            MediaQuery.sizeOf(sheetContext).height * 0.7 -
            MediaQuery.viewInsetsOf(sheetContext).bottom;
        return BottomSystemSafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxSheetHeight.clamp(200.h, double.infinity),
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 20.h),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36.w,
                    height: 4.h,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  SizedBox(height: 16.h),
                  Text(
                    l10n.chatMoreEmojis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16.sp,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 16.h),
                  Wrap(
                    spacing: 10.w,
                    runSpacing: 10.h,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final emoji in ChatBubbleBar.moreEmojis)
                        InkWell(
                          onTap: () => Navigator.pop(sheetContext, emoji),
                          borderRadius: BorderRadius.circular(14.r),
                          child: Container(
                            width: 48.w,
                            height: 48.w,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: const Color.fromRGBO(255, 255, 255, 0.08),
                              borderRadius: BorderRadius.circular(14.r),
                              border: Border.all(
                                color: const Color.fromRGBO(
                                  255,
                                  255,
                                  255,
                                  0.12,
                                ),
                              ),
                            ),
                            child: Text(
                              emoji,
                              style: TextStyle(fontSize: 24.sp),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (emoji != null && mounted) {
      widget.onEmojiSelected(emoji);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: _composing
          ? _buildComposer()
          : _buildActionRow(
              key: ValueKey(
                widget.anyMemberOnline ? 'emoji-row' : 'preset-row',
              ),
            ),
    );
    if (widget.enabled) return content;
    return Opacity(
      opacity: 0.42,
      child: IgnorePointer(child: content),
    );
  }

  /// Scrollable content on the leading side; keyboard (and optional more)
  /// pinned at the trailing end outside the scroll view.
  Widget _buildActionRow({required Key key}) {
    final l10n = context.l10n;
    final online = widget.anyMemberOnline;
    final presets = chatPresetsFor(l10n);
    // Keep this compact so 5 chat bubbles still fit above it when live.
    return Padding(
      key: key,
      padding: EdgeInsets.symmetric(horizontal: 16.w),
      child: FadedHorizontalRow(
        height: 44.h,
        gap: 8.w,
        veilWidth: 28.w,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (online) ...[
              _CircleAction(
                tooltip: l10n.chatMoreEmojis,
                onTap: _openMoreEmojis,
                child: Icon(
                  LucideIcons.smilePlus,
                  color: Colors.white,
                  size: 18.sp,
                ),
              ),
              SizedBox(width: 8.w),
            ],
            _CircleAction(
              tooltip: l10n.chatWriteCustomMessage,
              emphasized: true,
              onTap: _openComposer,
              child: Icon(
                LucideIcons.keyboard,
                color: const Color(0xff161616),
                size: 18.sp,
              ),
            ),
          ],
        ),
        children: online
            ? [
                for (var i = 0; i < ChatBubbleBar.quickEmojis.length; i++) ...[
                  if (i > 0) SizedBox(width: 6.w),
                  _EmojiChip(
                    emoji: ChatBubbleBar.quickEmojis[i],
                    onTap: () => widget.onEmojiSelected(
                      ChatBubbleBar.quickEmojis[i],
                    ),
                  ),
                ],
              ]
            : [
                for (var i = 0; i < presets.length; i++) ...[
                  if (i > 0) SizedBox(width: 6.w),
                  _PresetChip(
                    label: presets[i],
                    enabled: !_sending,
                    onTap: () => unawaited(_sendPreset(presets[i])),
                  ),
                ],
              ],
      ),
    );
  }

  Widget _buildComposer() {
    final l10n = context.l10n;
    final wordCount = _controller.text.trim().isEmpty
        ? 0
        : _controller.text.trim().split(RegExp(r'\s+')).length;
    final canSend =
        !_sending && ChatMessageRepository.sanitize(_controller.text) != null;

    return Padding(
      key: const ValueKey('composer'),
      padding: EdgeInsets.symmetric(horizontal: 16.w),
      child: SizedBox(
        height: 44.h,
        child: Row(
          children: [
            _CircleAction(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onTap: _closeComposer,
              child: Icon(LucideIcons.x, color: Colors.white, size: 16.sp),
            ),
            SizedBox(width: 8.w),
            Expanded(
              child: DecoratedBox(
                decoration: _glassFill(radius: 22.r),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14.w),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          inputFormatters: [
                            _WordLimitFormatter(ChatMessageRepository.maxWords),
                          ],
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.94),
                            fontSize: 15.sp,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                          ),
                          decoration: InputDecoration(
                            hintText: l10n.chatMessageHint,
                            hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.38),
                              fontSize: 15.sp,
                              fontWeight: FontWeight.w500,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => unawaited(_sendCustom()),
                        ),
                      ),
                      SizedBox(width: 8.w),
                      Text(
                        '$wordCount/${ChatMessageRepository.maxWords}',
                        style: TextStyle(
                          color: wordCount > ChatMessageRepository.maxWords
                              ? const Color(0xffff5a5f)
                              : Colors.white38,
                          fontSize: 10.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: 8.w),
            _CircleAction(
              tooltip: l10n.chatWriteCustomMessage,
              emphasized: canSend,
              fill: canSend ? widget.accent : null,
              onTap: canSend ? () => unawaited(_sendCustom()) : null,
              child: Icon(
                LucideIcons.send,
                color: canSend
                    ? (widget.accent.computeLuminance() > 0.55
                          ? const Color(0xff161616)
                          : Colors.white)
                    : Colors.white.withValues(alpha: 0.38),
                size: 16.sp,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

BoxDecoration _glassFill({required double radius}) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: 0.16),
        Colors.white.withValues(alpha: 0.06),
      ],
    ),
  );
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({
    required this.onTap,
    required this.child,
    this.enabled = true,
    this.padding,
  });

  final VoidCallback? onTap;
  final Widget child;
  final bool enabled;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(999);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          splashColor: Colors.white.withValues(alpha: 0.14),
          highlightColor: Colors.white.withValues(alpha: 0.06),
          onTap: enabled ? onTap : null,
          child: Ink(
            decoration: _glassFill(radius: 999),
            padding:
                padding ?? EdgeInsets.symmetric(horizontal: 14.w, vertical: 0),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _GlassChip(
      enabled: enabled,
      onTap: onTap,
      padding: EdgeInsets.symmetric(horizontal: 16.w),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.94),
          fontSize: 13.sp,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          height: 1.1,
        ),
      ),
    );
  }
}

class _EmojiChip extends StatelessWidget {
  const _EmojiChip({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _GlassChip(
      onTap: onTap,
      padding: EdgeInsets.symmetric(horizontal: 12.w),
      child: Text(emoji, style: TextStyle(fontSize: 20.sp, height: 1)),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.tooltip,
    required this.child,
    this.onTap,
    this.emphasized = false,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback? onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: emphasized
              ? Colors.white.withValues(alpha: 0.94)
              : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            splashColor: Colors.white.withValues(alpha: 0.16),
            highlightColor: Colors.white.withValues(alpha: 0.08),
            onTap: onTap,
            child: Ink(
              width: 40.w,
              height: 40.w,
              decoration: emphasized
                  ? const BoxDecoration(shape: BoxShape.circle)
                  : BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.16),
                          Colors.white.withValues(alpha: 0.06),
                        ],
                      ),
                    ),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hard-blocks edits that would push the message over [maxWords] words,
/// giving immediate feedback instead of only validating on send.
class _WordLimitFormatter extends TextInputFormatter {
  const _WordLimitFormatter(this.maxWords);

  final int maxWords;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final trimmed = newValue.text.trim();
    final words = trimmed.isEmpty
        ? const <String>[]
        : trimmed.split(RegExp(r'\s+'));
    if (words.length <= maxWords) return newValue;
    return oldValue;
  }
}
