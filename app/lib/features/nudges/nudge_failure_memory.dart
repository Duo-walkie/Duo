enum NudgeErrorSeverity { partial, full }

class NudgeErrorState {
  const NudgeErrorState({
    required this.severity,
    required this.message,
    required this.at,
  });

  final NudgeErrorSeverity severity;
  final String message;
  final DateTime at;
}

// Last delivery failure per group. Expires after [timeout] or on success.
class NudgeFailureMemory {
  NudgeFailureMemory._();

  static final NudgeFailureMemory instance = NudgeFailureMemory._();

  static const Duration timeout = Duration(minutes: 15);

  final Map<String, NudgeErrorState> _byGroupId = {};

  NudgeErrorState? forGroup(String groupId) {
    final entry = _byGroupId[groupId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > timeout) {
      _byGroupId.remove(groupId);
      return null;
    }
    return entry;
  }

  void record(String groupId, NudgeErrorSeverity severity, String message) {
    if (groupId.isEmpty) return;
    _byGroupId[groupId] = NudgeErrorState(
      severity: severity,
      message: message,
      at: DateTime.now(),
    );
  }

  void clearGroup(String groupId) {
    _byGroupId.remove(groupId);
  }

  void clearAll() {
    _byGroupId.clear();
  }
}
