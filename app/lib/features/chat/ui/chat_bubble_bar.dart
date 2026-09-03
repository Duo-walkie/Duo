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
  });

  final Color accent;

  /// When true (mixed or all online), text chips are replaced by emojis.
  final bool anyMemberOnline;

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
  final ScrollController _chipScrollController = ScrollController();
  final ScrollController _emojiScrollController = ScrollController();
  bool _composing = false;
  bool _sending = false;
  bool _showTrailingChipFade = false;
  bool _showTrailingEmojiFade = false;

  @override
  void initState() {
    super.initState();
    _chipScrollController.addListener(_updateChipScrollFade);
    _emojiScrollController.addListener(_updateEmojiScrollFade);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateChipScrollFade();
      _updateEmojiScrollFade();
    });
  }

  @override
  void didUpdateWidget(covariant ChatBubbleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anyMemberOnline != widget.anyMemberOnline) {
      // Online swaps presets → emoji row; leave the composer if it was open
      // so the emoji / "more" controls aren't hidden behind the text field.
      if (widget.anyMemberOnline && _composing) {
        _closeComposer();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_chipScrollController.hasClients) {
          _chipScrollController.jumpTo(0);
          _updateChipScrollFade();
        }
        if (_emojiScrollController.hasClients) {
          _emojiScrollController.jumpTo(0);
          _updateEmojiScrollFade();
        }
      });
    }
  }

  void _updateChipScrollFade() {
    if (!_chipScrollController.hasClients) return;
    final position = _chipScrollController.position;
    final canScroll = position.maxScrollExtent > 0;
    final atEnd = position.pixels >= position.maxScrollExtent - 2;
    final show = canScroll && !atEnd;
    if (show != _showTrailingChipFade && mounted) {
      setState(() => _showTrailingChipFade = show);
    }
  }

  void _updateEmojiScrollFade() {
    if (!_emojiScrollController.hasClients) return;
    final position = _emojiScrollController.position;
    final canScroll = position.maxScrollExtent > 0;
    final atEnd = position.pixels >= position.maxScrollExtent - 2;
    final show = canScroll && !atEnd;
    if (show != _showTrailingEmojiFade && mounted) {
      setState(() => _showTrailingEmojiFade = show);
    }
  }

  @override
  void dispose() {
    _chipScrollController.removeListener(_updateChipScrollFade);
    _emojiScrollController.removeListener(_updateEmojiScrollFade);
    _chipScrollController.dispose();
    _emojiScrollController.dispose();
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
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: _composing
          ? _buildComposer()
          : _buildActionRow(
              key: ValueKey(
                widget.anyMemberOnline ? 'emoji-row' : 'preset-row',
              ),
            ),
    );
  }

  /// Scrollable content on the leading side; keyboard (and optional more)
  /// pinned at the trailing end outside the scroll view.
  Widget _buildActionRow({required Key key}) {
    final l10n = context.l10n;
    final online = widget.anyMemberOnline;
    final presets = chatPresetsFor(l10n);
    // Online emoji chips are a touch taller than offline text presets —
    // keep this compact so 5 chat bubbles still fit above it when live.
    return SizedBox(
      key: key,
      height: online ? 44.h : 40.h,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.w),
        child: Row(
          children: [
            Expanded(
              child: online
                  ? _FadedHorizontalChipList(
                      controller: _emojiScrollController,
                      showTrailingFade: _showTrailingEmojiFade,
                      onScroll: _updateEmojiScrollFade,
                      children: [
                        for (final emoji in ChatBubbleBar.quickEmojis) ...[
                          _EmojiChip(
                            emoji: emoji,
                            onTap: () => widget.onEmojiSelected(emoji),
                          ),
                          SizedBox(width: 8.w),
                        ],
                      ],
                    )
                  : _FadedHorizontalChipList(
                      controller: _chipScrollController,
                      showTrailingFade: _showTrailingChipFade,
                      onScroll: _updateChipScrollFade,
                      children: [
                        for (final preset in presets) ...[
                          _PresetChip(
                            label: preset,
                            enabled: !_sending,
                            onTap: () => unawaited(_sendPreset(preset)),
                          ),
                          SizedBox(width: 8.w),
                        ],
                      ],
                    ),
            ),
            SizedBox(width: 8.w),
            if (online) ...[
              _MoreEmojisButton(accent: widget.accent, onTap: _openMoreEmojis),
              SizedBox(width: 8.w),
            ],
            _KeyboardButton(accent: widget.accent, onTap: _openComposer),
          ],
        ),
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
      child: Row(
        children: [
          IconButton(
            onPressed: _closeComposer,
            icon: const Icon(Icons.close_rounded, color: Colors.white70),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Container(
              // Taller, roomier pill than before (the previous container
              // felt cramped for composing a message) — extra vertical
              // padding plus a min height, while staying single-line so it
              // doesn't grow unpredictably and crowd the pinned close/send
              // buttons on either side.
              constraints: BoxConstraints(minHeight: 52.h),
              padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
              decoration: BoxDecoration(
                color: const Color(0xff2a2a2a),
                borderRadius: BorderRadius.circular(26.r),
              ),
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
                      style: TextStyle(color: Colors.white, fontSize: 16.sp),
                      decoration: InputDecoration(
                        hintText: l10n.chatMessageHint,
                        hintStyle: const TextStyle(color: Colors.white38),
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
          SizedBox(width: 8.w),
          IconButton(
            onPressed: canSend ? () => unawaited(_sendCustom()) : null,
            icon: Icon(
              Icons.send_rounded,
              color: canSend ? widget.accent : Colors.white24,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Horizontal chip row with a trailing fade when content continues off-screen.
class _FadedHorizontalChipList extends StatelessWidget {
  const _FadedHorizontalChipList({
    required this.controller,
    required this.showTrailingFade,
    required this.onScroll,
    required this.children,
  });

  final ScrollController controller;
  final bool showTrailingFade;
  final VoidCallback onScroll;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification ||
            notification is ScrollMetricsNotification) {
          onScroll();
        }
        return false;
      },
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) {
          if (!showTrailingFade) {
            return const LinearGradient(
              colors: [Colors.white, Colors.white],
            ).createShader(bounds);
          }
          return const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0.0, 0.62, 0.88],
          ).createShader(bounds);
        },
        child: ListView(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(right: 16.w),
          children: children,
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
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: const Color(0xff1f1f1f),
        borderRadius: BorderRadius.circular(20.r),
        child: InkWell(
          borderRadius: BorderRadius.circular(20.r),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 9.h),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
    return Material(
      color: const Color(0xff1f1f1f),
      borderRadius: BorderRadius.circular(20.r),
      child: InkWell(
        borderRadius: BorderRadius.circular(20.r),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
          child: Text(emoji, style: TextStyle(fontSize: 20.sp)),
        ),
      ),
    );
  }
}

class _MoreEmojisButton extends StatelessWidget {
  const _MoreEmojisButton({required this.accent, required this.onTap});

  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.chatMoreEmojis,
      child: Material(
        color: accent.withValues(alpha: 0.16),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(9.r),
            child: Icon(
              Icons.add_reaction_outlined,
              color: accent,
              size: 18.sp,
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyboardButton extends StatelessWidget {
  const _KeyboardButton({required this.accent, required this.onTap});

  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.chatWriteCustomMessage,
      child: Material(
        color: accent.withValues(alpha: 0.16),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(9.r),
            child: Icon(Icons.keyboard_rounded, color: accent, size: 18.sp),
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
