import { randomBytes, createHash } from "node:crypto";
import { config } from "../config.js";
import { sendAndroidDataPushes } from "../firebase/messaging.js";
import { getRealtimeDatabase } from "../firebase/database.js";
import { getVoiceNudgeBucket } from "../firebase/storage.js";
import { HttpError } from "../http/httpError.js";
import { logger } from "../logger.js";
import { createLiveKitRoomServiceClient, isLiveKitNotFound } from "../livekit/tokens.js";

const maxMembers = 6;
const defaultMaxTalkMs = 60_000;

export type CreateGroupInput = {
  ownerUserId: string;
  name: string;
};

export type CreateInviteInput = {
  groupId: string;
  userId: string;
  maxUses: number;
  expiresInHours: number;
};

export type JoinInviteInput = {
  userId: string;
  inviteCode: string;
};

export type GroupMemberActionInput = {
  groupId: string;
  userId: string;
};

export type RemoveGroupMemberInput = GroupMemberActionInput & {
  memberUserId: string;
};

export async function createGroup(input: CreateGroupInput) {
  const db = getRealtimeDatabase();
  await requireActiveUser(input.ownerUserId);

  const groupRef = db.ref("groups").push();
  const groupId = groupRef.key;

  if (!groupId) {
    throw new HttpError(500, "group_id_failed", "Failed to allocate group id.");
  }

  const now = nowSeconds();
  const livekitRoomName = `group_${groupId}`;

  await db.ref().update({
    [`groups/${groupId}`]: {
      name: input.name,
      ownerUserId: input.ownerUserId,
      livekitRoomName,
      singleSpeaker: true,
      maxTalkMs: defaultMaxTalkMs,
      maxMembers,
      createdAt: now,
      archivedAt: null,
      groupState: "active"
    },
    [`groupMembers/${groupId}/${input.ownerUserId}`]: {
      role: "owner",
      memberState: "active",
      mutedBySelf: false,
      joinedAt: now,
      leftAt: null
    },
    [`userGroups/${input.ownerUserId}/${groupId}`]: {
      role: "owner",
      joinedAt: now
    },
    [`livekitRooms/${groupId}`]: {
      groupId,
      roomName: livekitRoomName,
      serverUrlKey: "default",
      roomStrategy: "one_room_per_group",
      createdAt: now,
      roomState: "active"
    },
    [`memberAvailability/${groupId}/${input.ownerUserId}`]: defaultAvailability(now)
  });

  return {
    groupId,
    livekitRoomName
  };
}

export async function createInvite(input: CreateInviteInput) {
  const db = getRealtimeDatabase();
  await requireActiveUser(input.userId);
  await requireActiveGroupMember(input.groupId, input.userId);
  const group = await requireActiveGroup(input.groupId);
  const now = nowSeconds();
  const operationId = randomBytes(8).toString("hex");
  if (!(await acquireGroupActivityLock(input.groupId, operationId, now))) {
    throw new HttpError(409, "group_not_active", "Group is being deleted.");
  }
  try {
    const inviteRef = db.ref("groupInvites").push();
    const inviteId = inviteRef.key;
    if (!inviteId) {
      throw new HttpError(500, "invite_id_failed", "Failed to allocate invite id.");
    }

    let inviteCode = "";
    let inviteCodeHash = "";
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const candidate = generateInviteCode();
      const candidateHash = hashInviteCode(candidate);
      if (!(await db.ref(`inviteCodeIndex/${candidateHash}`).get()).exists()) {
        inviteCode = candidate;
        inviteCodeHash = candidateHash;
        break;
      }
    }
    if (!inviteCode) {
      throw new HttpError(500, "invite_code_failed", "Failed to allocate invite code.");
    }
    const expiresAt = now + input.expiresInHours * 60 * 60;
    await db.ref().update({
      [`groupInvites/${inviteId}`]: {
        inviteId,
        groupId: input.groupId,
        inviteCodeHash,
        createdByUserId: input.userId,
        maxUses: Math.min(
          input.maxUses,
          Math.max(Math.max(group.maxMembers, maxMembers) - 1, 1)
        ),
        usedCount: 0,
        expiresAt,
        revokedAt: null,
        createdAt: now
      },
      [`inviteCodeIndex/${inviteCodeHash}`]: inviteId
    });

    return {
      inviteId,
      groupId: input.groupId,
      inviteCode,
      inviteUrl: buildInviteUrl(inviteCode),
      expiresAt
    };
  } finally {
    await db
      .ref(`groupLifecycleLocks/${input.groupId}/operations/${operationId}`)
      .remove()
      .catch(() => undefined);
  }
}

export async function joinInvite(input: JoinInviteInput) {
  const db = getRealtimeDatabase();
  await requireActiveUser(input.userId);

  const invite = await findActiveInvite(input.inviteCode);
  const group = await requireActiveGroup(invite.groupId);
  const memberRef = db.ref(`groupMembers/${invite.groupId}/${input.userId}`);
  const now = nowSeconds();
  const joinOperationId = randomBytes(8).toString("hex");
  if (!(await acquireGroupActivityLock(invite.groupId, joinOperationId, now))) {
    throw new HttpError(409, "group_not_active", "Group is being deleted.");
  }

  try {
    const existingMember = await memberRef.get();
    if (
      existingMember.exists() &&
      (existingMember.child("memberState").val() ?? "active") === "active"
    ) {
      await db.ref(`userGroups/${input.userId}/${invite.groupId}`).set({
        role: existingMember.child("role").val()?.toString() ?? "member",
        joinedAt: readNumber(existingMember.child("joinedAt").val(), now)
      });
      return {
        groupId: invite.groupId,
        alreadyMember: true
      };
    }

    const capacity = Math.max(group.maxMembers, maxMembers);
    await reserveInviteUse(invite.inviteId, input.inviteCode, now);
    const joinNonce = randomBytes(8).toString("hex");
    const membersRef = db.ref(`groupMembers/${invite.groupId}`);
    const joinResult = await membersRef.transaction((current) => {
      const members = isRecord(current) ? { ...current } : {};
      const currentMember = members[input.userId];
      if (
        isRecord(currentMember) &&
        (currentMember.memberState ?? "active") === "active"
      ) {
        return;
      }

      const activeCount = Object.values(members).filter(
        (member) =>
          isRecord(member) && (member.memberState ?? "active") === "active"
      ).length;
      if (activeCount >= capacity) return;

      members[input.userId] = {
        role: "member",
        memberState: "active",
        mutedBySelf: false,
        joinedAt: now,
        leftAt: null,
        joinNonce
      };
      return members;
    });

    if (!joinResult.committed) {
      await releaseInviteUse(invite.inviteId);
      const latestMember = await memberRef.get();
      if (
        latestMember.exists() &&
        (latestMember.child("memberState").val() ?? "active") === "active"
      ) {
        await db.ref(`userGroups/${input.userId}/${invite.groupId}`).set({
          role: latestMember.child("role").val()?.toString() ?? "member",
          joinedAt: readNumber(latestMember.child("joinedAt").val(), now)
        });
        return { groupId: invite.groupId, alreadyMember: true };
      }
      throw new HttpError(
        409,
        "group_full",
        "Group already has the maximum number of members."
      );
    }

    await db.ref().update({
      [`groupMembers/${invite.groupId}/${input.userId}/joinNonce`]: null,
      [`userGroups/${input.userId}/${invite.groupId}`]: {
        role: "member",
        joinedAt: now
      },
      [`memberAvailability/${invite.groupId}/${input.userId}`]:
        defaultAvailability(now)
    });

    return {
      groupId: invite.groupId,
      alreadyMember: false
    };
  } finally {
    await db
      .ref(`groupLifecycleLocks/${invite.groupId}/operations/${joinOperationId}`)
      .remove()
      .catch(() => undefined);
  }
}

export async function listGroupsForUser(userId: string) {
  const db = getRealtimeDatabase();
  await requireActiveUser(userId);

  const indexVersion = (await db.ref(`userGroupIndexVersion/${userId}`).get()).val();
  if (indexVersion !== 1) {
    const memberships = await db.ref("groupMembers").get();
    const indexed: Record<string, unknown> = {};
    if (isRecord(memberships.val())) {
      for (const [groupId, rawMembers] of Object.entries(
        memberships.val() as Record<string, unknown>
      )) {
        if (!isRecord(rawMembers)) continue;
        const member = rawMembers[userId];
        if (!isRecord(member) || (member.memberState ?? "active") !== "active") continue;
        indexed[groupId] = {
          role: member.role?.toString() ?? "member",
          joinedAt: readNumber(member.joinedAt, 0)
        };
      }
    }
    await db.ref(`userGroups/${userId}`).set(indexed);
    await db.ref(`userGroupIndexVersion/${userId}`).set(1);
  }

  const index = await db.ref(`userGroups/${userId}`).get();
  if (!isRecord(index.val())) return { groups: [] };

  const groups = (
    await Promise.all(
      Object.keys(index.val() as Record<string, unknown>).map(async (groupId) => {
        const snapshot = await db.ref(`groups/${groupId}`).get();
        if (
          !snapshot.exists() ||
          (snapshot.child("groupState").val() ?? "active") !== "active"
        ) {
          await db.ref(`userGroups/${userId}/${groupId}`).remove();
          return null;
        }
        return {
          groupId,
          name: snapshot.child("name").val()?.toString() ?? "Friends",
          ownerUserId: snapshot.child("ownerUserId").val()?.toString() ?? "",
          livekitRoomName:
            snapshot.child("livekitRoomName").val()?.toString() ?? `group_${groupId}`,
          groupState: "active"
        };
      })
    )
  ).filter((group) => group !== null);

  return { groups };
}

export async function listGroupMembers(input: GroupMemberActionInput) {
  const db = getRealtimeDatabase();
  await requireActiveGroup(input.groupId);
  await requireActiveGroupMember(input.groupId, input.userId);
  const snapshot = await db.ref(`groupMembers/${input.groupId}`).get();
  if (!isRecord(snapshot.val())) return { members: [] };

  const members = (
    await Promise.all(
      Object.entries(snapshot.val() as Record<string, unknown>).map(
        async ([userId, raw]) => {
          if (
            !isRecord(raw) ||
            (raw.memberState ?? "active") !== "active"
          ) {
            return null;
          }
          const user = await db.ref(`users/${userId}`).get();
          return {
            userId,
            displayName: user.child("displayName").val()?.toString() ?? userId,
            role: raw.role?.toString() ?? "member",
            memberState: "active",
            profilePhotoUrl:
              user.child("profilePhotoUrl").val()?.toString() ?? null,
            profilePhotoBase64:
              user.child("profilePhotoBase64").val()?.toString() ?? null,
            avatarAsset: user.child("avatarAsset").val()?.toString() ?? null
          };
        }
      )
    )
  ).filter((member) => member !== null);

  return { members };
}

export async function removeGroupMember(input: RemoveGroupMemberInput) {
  const group = await requireGroupOwner(input.groupId, input.userId);
  if (input.memberUserId === group.ownerUserId) {
    throw new HttpError(409, "cannot_remove_owner", "The group owner cannot be removed.");
  }

  const db = getRealtimeDatabase();
  const memberRef = db.ref(`groupMembers/${input.groupId}/${input.memberUserId}`);
  const now = nowSeconds();
  // RTDB transactions often invoke the handler first with null (optimistic
  // local guess). Returning undefined there aborts with no retry — which left
  // members stuck as active while cleanup still wiped userGroups. Returning
  // null on null lets the SDK retry with the real server value.
  const result = await memberRef.transaction((current) => {
    if (current === null) return null;
    if (!isRecord(current) || (current.memberState ?? "active") !== "active") {
      return;
    }
    if (current.role === "owner") return;
    return {
      ...current,
      memberState: "removed",
      leftAt: now,
      removedAt: now,
      removedByUserId: input.userId
    };
  });

  if (!result.committed) {
    const current = await memberRef.get();
    const stillActive =
      current.exists() &&
      (current.child("memberState").val() ?? "active") === "active";
    if (stillActive && current.child("role").val() === "owner") {
      throw new HttpError(409, "cannot_remove_owner", "The group owner cannot be removed.");
    }
    if (stillActive) {
      throw new HttpError(
        409,
        "member_remove_failed",
        "Could not remove this member. Please try again."
      );
    }
    // Already left/removed — still sweep leftover session state.
    await cleanupMemberState(input.groupId, input.memberUserId, "removed_by_owner");
    return { removed: true, alreadyRemoved: true };
  }

  await cleanupMemberState(input.groupId, input.memberUserId, "removed_by_owner");
  await notifyUsers(
    [input.memberUserId],
    "👋 Removed from group",
    `You were removed from ${group.name}.`,
    { type: "group_removed", groupId: input.groupId }
  );

  return { removed: true, alreadyRemoved: false };
}

export async function leaveGroup(input: GroupMemberActionInput) {
  const db = getRealtimeDatabase();
  const group = await requireActiveGroup(input.groupId);
  const memberRef = db.ref(`groupMembers/${input.groupId}/${input.userId}`);
  const member = await memberRef.get();
  const memberRole = member.child("role").val()?.toString() ?? "member";
  if (memberRole === "owner" || group.ownerUserId === input.userId) {
    throw new HttpError(
      409,
      "owner_must_delete_group",
      "Owners must delete the group. Ownership transfer is not supported yet."
    );
  }
  if (
    !member.exists() ||
    (member.child("memberState").val() ?? "active") !== "active"
  ) {
    await cleanupMemberState(input.groupId, input.userId, "member_left");
    return { left: true, alreadyLeft: true };
  }

  const now = nowSeconds();
  // Same optimistic-null handling as removeGroupMember — see comment there.
  const result = await memberRef.transaction((current) => {
    if (current === null) return null;
    if (!isRecord(current) || (current.memberState ?? "active") !== "active") {
      return;
    }
    if (current.role === "owner") return;
    return {
      ...current,
      memberState: "left",
      leftAt: now
    };
  });

  if (!result.committed) {
    const current = await memberRef.get();
    const stillActive =
      current.exists() &&
      (current.child("memberState").val() ?? "active") === "active";
    if (stillActive && current.child("role").val() === "owner") {
      throw new HttpError(
        409,
        "owner_must_delete_group",
        "Owners must delete the group. Ownership transfer is not supported yet."
      );
    }
    if (stillActive) {
      throw new HttpError(
        409,
        "member_leave_failed",
        "Could not leave this group. Please try again."
      );
    }
    await cleanupMemberState(input.groupId, input.userId, "member_left");
    return { left: true, alreadyLeft: true };
  }

  await cleanupMemberState(input.groupId, input.userId, "member_left");
  return { left: true, alreadyLeft: false };
}

export async function deleteGroup(input: GroupMemberActionInput) {
  const db = getRealtimeDatabase();
  const group = await requireGroupOwner(input.groupId, input.userId);
  const lifecycleRef = db.ref(`groupLifecycleLocks/${input.groupId}`);
  if (!(await acquireGroupDeletionLock(input.groupId))) {
    throw new HttpError(
      409,
      "group_change_in_progress",
      "A group change is in progress. Try deleting the group again."
    );
  }
  const groupRef = db.ref(`groups/${input.groupId}`);
  // Same optimistic-null handling as removeGroupMember — aborting on the first
  // null callback leaves groups stuck undeletable.
  const deleting = await groupRef.transaction((current) => {
    if (current === null) return null;
    if (!isRecord(current)) return;
    if (
      current.ownerUserId !== input.userId ||
      (current.groupState ?? "active") !== "active"
    ) {
      return;
    }
    return { ...current, groupState: "deleting", deletingAt: nowSeconds() };
  });

  if (!deleting.committed) {
    await lifecycleRef.remove();
    throw new HttpError(409, "group_not_active", "Group is already being deleted.");
  }

  try {
    const membersSnapshot = await db.ref(`groupMembers/${input.groupId}`).get();
    const memberUserIds = isRecord(membersSnapshot.val())
      ? Object.entries(membersSnapshot.val() as Record<string, unknown>)
          .filter(
            ([, member]) =>
              isRecord(member) && (member.memberState ?? "active") === "active"
          )
          .map(([userId]) => userId)
      : [];

    await disconnectLiveKitRoom(group.livekitRoomName);
    const updates: Record<string, unknown> = {
      [`groups/${input.groupId}`]: null,
      [`groupMembers/${input.groupId}`]: null,
      [`livekitRooms/${input.groupId}`]: null,
      [`memberAvailability/${input.groupId}`]: null,
      [`mediaVolume/${input.groupId}`]: null,
      [`groupMessages/${input.groupId}`]: null,
      [`talkLocks/${input.groupId}`]: null,
      [`talkSessions/${input.groupId}`]: null,
      [`statusEvents/${input.groupId}`]: null,
      [`dailyUsage/${input.groupId}`]: null,
      [`notificationEvents/${input.groupId}`]: null,
      [`groupLifecycleLocks/${input.groupId}`]: null
    };
    for (const userId of memberUserIds) {
      updates[`userGroups/${userId}/${input.groupId}`] = null;
    }
    await addFlatGroupCleanup(updates, input.groupId);
    await db.ref().update(updates);
    await notifyUsers(
      memberUserIds,
      "🗑️ Group deleted",
      `${group.name} was permanently deleted.`,
      { type: "group_deleted", groupId: input.groupId }
    );
    return { deleted: true };
  } catch (error) {
    await groupRef
      .update({
        groupState: "active",
        deletingAt: null,
        deletionFailedAt: nowSeconds()
      })
      .catch(() => undefined);
    await lifecycleRef.remove().catch(() => undefined);
    throw error;
  }
}

/**
 * Fully purges a user's account: every per-group row the user has ever
 * written (membership, presence, usage, unread piles, sessions, locks, talk
 * state) plus the user's own records. Runs with admin privileges so it works
 * regardless of the client-facing security rules, and covers groups created
 * before the deletion path existed.
 */
export async function purgeUserAccount(userId: string) {
  const db = getRealtimeDatabase();

  const groupIds = new Set<string>();
  const indexSnap = await db.ref(`userGroups/${userId}`).get();
  if (isRecord(indexSnap.val())) {
    for (const groupId of Object.keys(indexSnap.val() as Record<string, unknown>)) {
      groupIds.add(groupId);
    }
  }

  // Sweep groupMembers as an authoritative source too — catches groups whose
  // inverse index is missing/stale for this legacy account.
  const membersSnap = await db.ref("groupMembers").get();
  if (isRecord(membersSnap.val())) {
    for (const [groupId, rawMembers] of Object.entries(
      membersSnap.val() as Record<string, unknown>
    )) {
      if (isRecord(rawMembers) && rawMembers[userId] != null) {
        groupIds.add(groupId);
      }
    }
  }

  for (const groupId of groupIds) {
    const memberRef = db.ref(`groupMembers/${groupId}/${userId}`);
    const member = await memberRef.get();
    const role = member.child("role").val()?.toString() ?? "member";
    const groupSnap = await db.ref(`groups/${groupId}`).get();
    const ownerUserId = groupSnap.child("ownerUserId").val()?.toString();

    if (ownerUserId === userId || role === "owner") {
      // The deleted user owns this group — tear the whole group down.
      try {
        await deleteGroup({ groupId, userId });
        continue;
      } catch (error) {
        // deleteGroup enforces active-owner guards that may be stale on a
        // deleted account; fall through to removing just this user's rows.
        logger.warn(
          {
            checkpoint: "ACCOUNT-PURGE-W1",
            groupId,
            userId,
            error: error instanceof Error ? error.message : String(error)
          },
          "owned group teardown failed during account purge; removing member rows only"
        );
      }
    }

    // Remove this member from the group but keep the group alive for the
    // remaining members. cleanupMemberState handles sessions/locks/talk, and
    // we additionally drop membership, availability, usage, and the unread
    // pile rows the user owned.
    const updates: Record<string, unknown> = {
      [`groupMembers/${groupId}/${userId}`]: null,
      [`memberAvailability/${groupId}/${userId}`]: null,
      [`mediaVolume/${groupId}/${userId}`]: null,
      [`dailyUsage/${groupId}/${userId}`]: null,
      [`chatUnread/${groupId}/${userId}`]: null,
      [`userGroups/${userId}/${groupId}`]: null
    };
    await db.ref().update(updates);
    await cleanupMemberState(groupId, userId, "account_deleted");
  }

  const finalUpdates: Record<string, unknown> = {
    [`users/${userId}`]: null,
    [`userDevices/${userId}`]: null,
    [`userSettings/${userId}`]: null,
    [`userGroups/${userId}`]: null,
    [`userGroupIndexVersion/${userId}`]: null,
    [`userEngagement/${userId}`]: null
  };

  // Purge any notification deliveries involving this user (best effort, so a
  // missing doc never blocks the wipe).
  const deliveriesSnap = await db.ref("notificationDeliveries").get();
  if (isRecord(deliveriesSnap.val())) {
    for (const [eventId, raw] of Object.entries(
      deliveriesSnap.val() as Record<string, unknown>
    )) {
      if (
        isRecord(raw) &&
        (raw.senderUserId === userId || raw.recipientUserId === userId)
      ) {
        finalUpdates[`notificationDeliveries/${eventId}`] = null;
      }
    }
  }

  await db.ref().update(finalUpdates);
  logger.info(
    { checkpoint: "ACCOUNT-PURGE-01", userId, groupsTouched: groupIds.size },
    "account fully purged"
  );
  return { purged: true, groupsTouched: groupIds.size };
}

/**
 * Keep only user ids that still have an active `users/{uid}` record.
 *
 * Missing `users/{uid}` means the account was deleted (account deletion wipes
 * that path). App uninstall does not — uninstall leaves `users/{uid}` intact,
 * so those members are correctly retained here.
 */
export async function filterActiveAccountUserIds(userIds: string[]) {
  if (userIds.length === 0) return [];
  const db = getRealtimeDatabase();
  const active: string[] = [];
  for (const userId of userIds) {
    const snapshot = await db.ref(`users/${userId}`).get();
    if (!snapshot.exists()) continue;
    if ((snapshot.child("accountState").val() ?? "active") !== "active") continue;
    active.push(userId);
  }
  return active;
}

const inVoiceSessionStates = new Set([
  "connecting",
  "live",
  "talking",
  "listening",
  "connected"
]);

/**
 * User IDs currently in an active voice session for a group, read from RTDB
 * `memberAvailability` presence. Mirrors the client's `isInVoiceSessionAt`
 * check (desiredState online + effectiveState in a voice-session state + not
 * stale), so no LiveKit server round-trip is needed.
 */
export async function listInVoiceSessionUserIds(groupId: string): Promise<string[]> {
  const snapshot = await getRealtimeDatabase().ref(`memberAvailability/${groupId}`).get();
  if (!snapshot.exists()) return [];

  const value = snapshot.val();
  if (!isRecord(value)) return [];

  const now = nowSeconds();
  const userIds: string[] = [];
  for (const [userId, raw] of Object.entries(value)) {
    if (!isRecord(raw)) continue;
    if ((raw.desiredState ?? "away") !== "online") continue;
    const staleAfterAt = readNumber(raw.staleAfterAt, 0);
    if (staleAfterAt > 0 && staleAfterAt <= now) continue;
    const effectiveState = String(raw.effectiveState ?? "");
    if (!inVoiceSessionStates.has(effectiveState)) continue;
    userIds.push(userId);
  }
  return userIds;
}

export async function requireActiveUser(userId: string) {
  const ref = getRealtimeDatabase().ref(`users/${userId}`);
  const snapshot = await ref.get();

  if (!snapshot.exists()) {
    const now = nowSeconds();
    await ref.set({
      displayName: defaultDisplayName(userId),
      authProvider: "anonymous",
      accountState: "active",
      createdAt: now,
      updatedAt: now,
      lastSeenAt: now
    });
    return;
  }

  if ((snapshot.child("accountState").val() ?? "active") !== "active") {
    throw new HttpError(403, "user_not_active", "User is not active.");
  }
}

export async function requireActiveGroup(groupId: string) {
  const snapshot = await getRealtimeDatabase().ref(`groups/${groupId}`).get();
  if (!snapshot.exists()) {
    throw new HttpError(404, "group_not_found", "Group does not exist.");
  }

  if ((snapshot.child("groupState").val() ?? "active") !== "active") {
    throw new HttpError(409, "group_not_active", "Group is not active.");
  }

  return {
    groupId,
    name: snapshot.child("name").val()?.toString() ?? "Friends",
    ownerUserId: snapshot.child("ownerUserId").val()?.toString() ?? "",
    maxMembers: readNumber(snapshot.child("maxMembers").val(), maxMembers),
    livekitRoomName: snapshot.child("livekitRoomName").val()?.toString() ?? `group_${groupId}`
  };
}

async function requireGroupOwner(groupId: string, userId: string) {
  const group = await requireActiveGroup(groupId);
  const member = await requireActiveGroupMember(groupId, userId);
  if (!isVerifiedGroupOwner(group.ownerUserId, member.role, userId)) {
    throw new HttpError(403, "owner_required", "Only the group owner can do this.");
  }
  return group;
}

export function isVerifiedGroupOwner(
  ownerUserId: string,
  memberRole: string,
  userId: string
) {
  return ownerUserId === userId && memberRole === "owner";
}

export async function requireActiveGroupMember(groupId: string, userId: string) {
  const snapshot = await getRealtimeDatabase().ref(`groupMembers/${groupId}/${userId}`).get();

  if (!snapshot.exists() || (snapshot.child("memberState").val() ?? "active") !== "active") {
    throw new HttpError(403, "not_group_member", "User is not an active group member.");
  }

  return {
    role: snapshot.child("role").val()?.toString() ?? "member"
  };
}

export async function requireActiveUserDevice(userId: string, deviceId: string) {
  const ref = getRealtimeDatabase().ref(`userDevices/${userId}/${deviceId}`);
  const snapshot = await ref.get();

  if (!snapshot.exists()) {
    const now = nowSeconds();
    await ref.set({
      platform: "android",
      appVersion: "unknown",
      deviceState: "active",
      createdAt: now,
      updatedAt: now,
      lastSeenAt: now
    });
    return;
  }

  if ((snapshot.child("deviceState").val() ?? "active") !== "active") {
    throw new HttpError(403, "device_not_active", "Device is not active for this user.");
  }
}

async function findActiveInvite(inviteCode: string) {
  const now = nowSeconds();
  const hash = hashInviteCode(inviteCode);
  const db = getRealtimeDatabase();
  const indexedId = (await db.ref(`inviteCodeIndex/${hash}`).get()).val()?.toString();
  if (indexedId) {
    const indexed = await db.ref(`groupInvites/${indexedId}`).get();
    if (isRecord(indexed.val())) {
      return activeInviteRecord(indexedId, indexed.val() as Record<string, unknown>, hash, now);
    }
  }

  // Legacy fallback: backfill links created before inviteCodeIndex existed.
  const snapshot = await db
    .ref("groupInvites")
    .orderByChild("inviteCodeHash")
    .equalTo(hash)
    .limitToFirst(1)
    .get();

  if (!snapshot.exists() || !isRecord(snapshot.val())) {
    throw new HttpError(404, "invite_not_found", "Invite code is invalid.");
  }

  for (const [inviteId, value] of Object.entries(snapshot.val() as Record<string, unknown>)) {
    if (!isRecord(value)) continue;
    if (value.inviteCodeHash !== hash) continue;
    await db.ref(`inviteCodeIndex/${hash}`).set(inviteId);
    return activeInviteRecord(inviteId, value, hash, now);
  }

  throw new HttpError(404, "invite_not_found", "Invite code is invalid.");
}

function activeInviteRecord(
  inviteId: string,
  value: Record<string, unknown>,
  expectedHash: string,
  now: number
) {
  const expiresAt = readNumber(value.expiresAt, 0);
  const maxUsesValue = readNumber(value.maxUses, 0);
  const usedCount = readNumber(value.usedCount, 0);
  const groupId = value.groupId?.toString() ?? "";
  if (
    value.inviteCodeHash !== expectedHash ||
    groupId.length === 0 ||
    value.revokedAt != null ||
    expiresAt <= now ||
    usedCount >= maxUsesValue
  ) {
    throw new HttpError(409, "invite_unavailable", "Invite is expired or fully used.");
  }
  return {
    inviteId,
    groupId,
    maxUses: maxUsesValue,
    usedCount,
    expiresAt
  };
}

async function reserveInviteUse(inviteId: string, inviteCode: string, now: number) {
  const hash = hashInviteCode(inviteCode);
  const inviteRef = getRealtimeDatabase().ref(`groupInvites/${inviteId}`);
  const snapshot = await inviteRef.get();
  const value = snapshot.val();
  if (!isRecord(value)) {
    throw new HttpError(409, "invite_unavailable", "Invite is expired or fully used.");
  }

  const maxUsesValue = readNumber(value.maxUses, 0);
  const expiresAt = readNumber(value.expiresAt, 0);
  if (
    value.inviteCodeHash !== hash ||
    value.revokedAt != null ||
    expiresAt <= now ||
    maxUsesValue <= 0
  ) {
    throw new HttpError(409, "invite_unavailable", "Invite is expired or fully used.");
  }

  // RTDB transactions always fire once with null first (even right after get()).
  // Returning undefined on that null aborts with no retry — every join then
  // looked “fully used” while usedCount stayed 0. Increment the counter leaf
  // and treat null as 0 so the first callback cannot abort the reservation.
  const result = await inviteRef.child("usedCount").transaction((current) => {
    const usedCount = current == null ? 0 : readNumber(current, 0);
    if (usedCount >= maxUsesValue) return;
    return usedCount + 1;
  });
  if (!result.committed) {
    throw new HttpError(409, "invite_unavailable", "Invite is expired or fully used.");
  }
}

async function releaseInviteUse(inviteId: string) {
  await getRealtimeDatabase()
    .ref(`groupInvites/${inviteId}/usedCount`)
    .transaction((current) => {
      const usedCount = current == null ? 0 : readNumber(current, 0);
      return Math.max(usedCount - 1, 0);
    });
}

async function acquireGroupActivityLock(
  groupId: string,
  operationId: string,
  now: number
) {
  const result = await getRealtimeDatabase()
    .ref(`groupLifecycleLocks/${groupId}`)
    .transaction((current) => {
      const lock = isRecord(current) ? current : {};
      if (lock.deleting === true) return;
      const operations = isRecord(lock.operations) ? { ...lock.operations } : {};
      // ponytail: 60-second lease avoids a dead group after a crashed request;
      // use renewable leases if group mutations ever legitimately exceed it.
      for (const [id, startedAt] of Object.entries(operations)) {
        if (readNumber(startedAt, 0) < now - 60) delete operations[id];
      }
      operations[operationId] = now;
      return { deleting: false, operations };
    });
  return result.committed;
}

async function acquireGroupDeletionLock(groupId: string) {
  const now = nowSeconds();
  const result = await getRealtimeDatabase()
    .ref(`groupLifecycleLocks/${groupId}`)
    .transaction((current) => {
      const lock = isRecord(current) ? current : {};
      if (lock.deleting === true) return;
      const operations = isRecord(lock.operations) ? lock.operations : {};
      const activeOperationExists = Object.values(operations).some(
        (startedAt) => readNumber(startedAt, 0) >= now - 60
      );
      if (activeOperationExists) return;
      return { deleting: true, operations: {} };
    });
  return result.committed;
}

async function cleanupMemberState(groupId: string, userId: string, reason: string) {
  const db = getRealtimeDatabase();
  const now = nowSeconds();
  const updates: Record<string, unknown> = {
    [`userGroups/${userId}/${groupId}`]: null,
    [`memberAvailability/${groupId}/${userId}`]: null,
    [`mediaVolume/${groupId}/${userId}`]: null,
    [`dailyUsage/${groupId}/${userId}`]: null
  };

  for (const collection of ["appServiceSessions", "livekitSessions"]) {
    const snapshot = await db
      .ref(collection)
      .orderByChild("groupId")
      .equalTo(groupId)
      .get();
    if (!isRecord(snapshot.val())) continue;
    for (const [id, raw] of Object.entries(snapshot.val() as Record<string, unknown>)) {
      if (!isRecord(raw) || raw.groupId !== groupId || raw.userId !== userId) continue;
      if (collection === "appServiceSessions") {
        updates[`${collection}/${id}/serviceState`] = "stopped";
        updates[`${collection}/${id}/stopReason`] = reason;
        updates[`${collection}/${id}/stoppedAt`] = now;
      } else {
        updates[`${collection}/${id}/connectionState`] = "disconnected";
        updates[`${collection}/${id}/disconnectedAt`] = now;
      }
    }
  }

  const lock = await db.ref(`talkLocks/${groupId}`).get();
  if (lock.child("holderUserId").val() === userId) {
    updates[`talkLocks/${groupId}`] = null;
  }
  const talks = await db.ref(`talkSessions/${groupId}`).get();
  if (isRecord(talks.val())) {
    for (const [talkId, raw] of Object.entries(talks.val() as Record<string, unknown>)) {
      if (!isRecord(raw) || raw.speakerUserId !== userId || raw.talkState !== "active") continue;
      updates[`talkSessions/${groupId}/${talkId}/talkState`] = "completed";
      updates[`talkSessions/${groupId}/${talkId}/endReason`] = reason;
      updates[`talkSessions/${groupId}/${talkId}/endedAt`] = now;
    }
  }
  const issuances = await db
    .ref("livekitTokenIssuances")
    .orderByChild("groupId")
    .equalTo(groupId)
    .get();
  if (isRecord(issuances.val())) {
    for (const [id, raw] of Object.entries(issuances.val() as Record<string, unknown>)) {
      if (!isRecord(raw) || raw.groupId !== groupId || raw.userId !== userId) continue;
      updates[`livekitTokenIssuances/${id}/revokedAt`] = now;
    }
  }

  await db.ref().update(updates);
  await disconnectLiveKitMember(groupId, userId);
}

async function addFlatGroupCleanup(updates: Record<string, unknown>, groupId: string) {
  const db = getRealtimeDatabase();
  for (const collection of [
    "groupInvites",
    "appServiceSessions",
    "livekitSessions",
    "livekitTokenIssuances",
    "voiceNudges"
  ]) {
    const snapshot = await db
      .ref(collection)
      .orderByChild("groupId")
      .equalTo(groupId)
      .get();
    if (!isRecord(snapshot.val())) continue;
    for (const [id, raw] of Object.entries(snapshot.val() as Record<string, unknown>)) {
      if (!isRecord(raw) || raw.groupId !== groupId) continue;
      updates[`${collection}/${id}`] = null;
      if (collection === "groupInvites" && typeof raw.inviteCodeHash === "string") {
        updates[`inviteCodeIndex/${raw.inviteCodeHash}`] = null;
      }
    }
  }

  const events = await db.ref(`notificationEvents/${groupId}`).get();
  if (isRecord(events.val())) {
    const eventIds = Object.keys(events.val() as Record<string, unknown>);
    for (const eventId of eventIds) {
      updates[`notificationDeliveries/${eventId}`] = null;
    }
    try {
      const bucket = getVoiceNudgeBucket();
      await Promise.all(
        eventIds.map((eventId) =>
          bucket.file(`voiceNudges/${eventId}.m4a`).delete({ ignoreNotFound: true })
        )
      );
    } catch (error) {
      logger.warn({ error, groupId }, "group voice nudge media cleanup failed");
    }
  }
}

async function notifyUsers(
  userIds: string[],
  title: string,
  body: string,
  data: Record<string, string>
) {
  const db = getRealtimeDatabase();
  const tokens: string[] = [];
  for (const userId of userIds) {
    const devices = await db.ref(`userDevices/${userId}`).get();
    if (!isRecord(devices.val())) continue;
    for (const raw of Object.values(devices.val() as Record<string, unknown>)) {
      if (!isRecord(raw) || raw.deviceState !== "active") continue;
      const token = raw.fcmToken?.toString();
      if (token) tokens.push(token);
    }
  }
  try {
    await sendAndroidDataPushes(
      tokens.map((token) => ({
        token,
        data: { ...data, title, body }
      })),
      10 * 60 * 1000
    );
  } catch (error) {
    logger.warn({ error, userCount: userIds.length }, "group lifecycle push failed");
  }
}

async function disconnectLiveKitMember(groupId: string, userId: string) {
  const client = createLiveKitRoomServiceClient();
  if (!client) return;
  try {
    const group = await getRealtimeDatabase().ref(`groups/${groupId}`).get();
    const roomName = group.child("livekitRoomName").val()?.toString() ?? `group_${groupId}`;
    const participants = await client.listParticipants(roomName);
    await Promise.all(
      participants
        .filter((participant) => participant.identity.startsWith(`${groupId}:${userId}:`))
        .map((participant) =>
          client.removeParticipant(roomName, participant.identity, {
            revokeTokenTs: BigInt(nowSeconds())
          })
        )
    );
  } catch (error) {
    // Empty / never-created rooms return 404 — expected when the member was
    // not in an active LiveKit session. Only warn on unexpected failures.
    if (!isLiveKitNotFound(error)) {
      logger.warn({ error, groupId, userId }, "LiveKit member disconnect failed");
    }
  }
}

async function disconnectLiveKitRoom(roomName: string) {
  const client = createLiveKitRoomServiceClient();
  if (!client) return;
  try {
    const participants = await client.listParticipants(roomName);
    await Promise.all(
      participants.map((participant) =>
        client.removeParticipant(roomName, participant.identity, {
          revokeTokenTs: BigInt(nowSeconds())
        })
      )
    );
    await client.deleteRoom(roomName);
  } catch (error) {
    if (!isLiveKitNotFound(error)) {
      logger.warn({ error, roomName }, "LiveKit room deletion failed");
    }
  }
}

function defaultAvailability(now: number) {
  return {
    activeDeviceId: null,
    activeServiceSessionId: null,
    activeLivekitSessionId: null,
    desiredState: "away",
    effectiveState: "away",
    serviceState: "stopped",
    livekitConnectionState: "disconnected",
    canReceiveLiveAudio: false,
    // Placeholder until the member actually connects — the client decides
    // the real starting mode in OnlineRepository.goOnline (walkie-talkie by
    // default, or call mode if peers are already connected that way).
    connectionMode: "walkieTalkie",
    lastHeartbeatAt: now,
    staleAfterAt: now,
    updatedAt: now
  };
}

function generateInviteCode() {
  return randomBytes(5).toString("base64url").toUpperCase();
}

function buildInviteUrl(inviteCode: string) {
  const baseUrl = (
    config.PUBLIC_INVITE_BASE_URL ?? `${config.PUBLIC_API_BASE_URL.replace(/\/$/, "")}/invite`
  ).replace(/\/$/, "");
  return `${baseUrl}/${encodeURIComponent(inviteCode)}`;
}

function hashInviteCode(inviteCode: string) {
  return createHash("sha256").update(inviteCode.trim().toUpperCase()).digest("hex");
}

function defaultDisplayName(userId: string) {
  const suffix = userId.length >= 4 ? userId.slice(0, 4) : userId;
  return `Friend ${suffix}`;
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readNumber(value: unknown, fallback: number) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}
