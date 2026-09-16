import 'package:one_one_app/one_one.dart';

/// Local record of groups where the current user has already created an
/// outbound invite and is still waiting for someone to join.
///
/// Used so home can show an "Invited" placeholder while the friends strip
/// has no joined peers yet. Cleared once another active member appears.
class PendingGroupInvitesStore {
  const PendingGroupInvitesStore._();

  static String _key(String userId) => 'one_one_pending_group_invites_$userId';

  static Future<Set<String>> read(String userId) async {
    if (userId.isEmpty) return const {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final values = prefs.getStringList(_key(userId)) ?? const <String>[];
      return values.where((id) => id.isNotEmpty).toSet();
    } catch (_) {
      return const {};
    }
  }

  static Future<void> mark(String userId, String groupId) async {
    if (userId.isEmpty || groupId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = Set<String>.of(await read(userId))..add(groupId);
      await prefs.setStringList(_key(userId), next.toList(growable: false));
    } catch (_) {
      // Best-effort local cache for home UI only.
    }
  }

  static Future<void> clear(String userId, String groupId) async {
    if (userId.isEmpty || groupId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = Set<String>.of(await read(userId))..remove(groupId);
      await prefs.setStringList(_key(userId), next.toList(growable: false));
    } catch (_) {
      // Best-effort local cache for home UI only.
    }
  }
}
