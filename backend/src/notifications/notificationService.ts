import { getRealtimeDatabase } from "../firebase/database.js";
import {
  isPermanentMessagingTargetError,
  sendAndroidDataPushes,
  sendPushToTokens
} from "../firebase/messaging.js";
import { config } from "../config.js";
import {
  filterActiveAccountUserIds,
  listInVoiceSessionUserIds,
  requireActiveGroup,
  requireActiveGroupMember,
  requireActiveUser,
  requireActiveUserDevice
} from "../groups/groupService.js";
import { HttpError } from "../http/httpError.js";
import { logger } from "../logger.js";
import { chatUnreadTtlSeconds, nextChatUnread } from "./chatUnread.js";
import { createAckTicket } from "./nudgeDeliveryService.js";
import { enforceNudgeRateLimits } from "./nudgeRateLimiter.js";

export type FriendLiveInput = {
  groupId: string;
  senderUserId: string;
  deviceId: string;
  serviceSessionId: string;
  livekitSessionId: string;
};

export type NudgeInput = {
  groupId: string;
  senderUserId: string;
  targetScope: "single_friend" | "all_friends" | "selected_friends";
  targetUserId?: string;
  targetUserIds?: string[];
};

export type GoneOfflineReason =
  | "peer_left"
  | "inactivity"
  | "daily_usage_cap"
  | "network_loss";

export type GoneOfflineInput = {
  groupId: string;
  userId: string;
  deviceId: string;
  reason: GoneOfflineReason;
};

export type ChatMessageInput = {
  groupId: string;
  senderUserId: string;
  messageId?: string;
  text?: string;
};

type RecipientDevice = {
  userId: string;
  deviceId: string;
  fcmToken: string;
};

const friendLiveDedupeSeconds = 60;
const goneOfflineDedupeSeconds = 60;
const actionableNudgeTtlMs = 10 * 60 * 1000;
const goneOfflineTtlMs = 10 * 60 * 1000;

const goneOfflineCopy: Record<
  GoneOfflineReason,
  { title: string; body: string }
> = {
  peer_left: {
    title: "😴 You're offline",
    body: "The other participant has gone offline. You are now offline."
  },
  inactivity: {
    title: "😴 You're offline",
    body: "Room closed due to inactivity. Send a nudge to go online again 👋"
  },
  daily_usage_cap: {
    title: "😴 You're offline",
    body: "Daily usage limit reached. You can go online again tomorrow 🌙"
  },
  network_loss: {
    title: "😴 You're offline",
    body: "Connection lost. You are now offline."
  }
};

export async function sendFriendLiveNotification(input: FriendLiveInput) {
  const db = getRealtimeDatabase();
  await requireActiveUser(input.senderUserId);
  await requireActiveGroup(input.groupId);
  await requireActiveGroupMember(input.groupId, input.senderUserId);
  await requireActiveUserDevice(input.senderUserId, input.deviceId);

  const availabilitySnapshot = await db
    .ref(`memberAvailability/${input.groupId}/${input.senderUserId}`)
    .get();

  if (!availabilitySnapshot.exists()) {
    throw new HttpError(409, "availability_missing", "Sender availability is missing.");
  }

  if (
    availabilitySnapshot.child("desiredState").val() !== "online" ||
    availabilitySnapshot.child("effectiveState").val() !== "live" ||
    availabilitySnapshot.child("canReceiveLiveAudio").val() !== true
  ) {
    throw new HttpError(
      409,
      "sender_not_live",
      "Friend-live notification can only be sent after the sender is effectively live."
    );
  }

  const now = nowSeconds();
  const dedupedEvent = await findRecentNotificationEvent({
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    eventType: "friend_live",
    since: now - friendLiveDedupeSeconds
  });

  if (dedupedEvent) {
    return {
      notificationEventId: dedupedEvent.notificationEventId,
      eventType: "friend_live",
      deduped: true,
      recipientUsers: dedupedEvent.targetUserIds.length,
      targetDevices: 0,
      sent: 0,
      failed: 0,
      skipped: 0
    };
  }

  const senderName = await readDisplayName(input.senderUserId);
  const recipientUserIds = await activeRecipientUserIds(input.groupId, input.senderUserId);
  const recipientDevices = await collectRecipientDevices(recipientUserIds);
  const notificationEventId = await createNotificationEvent({
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    eventType: "friend_live",
    targetScope: "all_friends",
    targetUserIds: recipientUserIds,
    createdAt: now,
    metadata: {
      serviceSessionId: input.serviceSessionId,
      livekitSessionId: input.livekitSessionId
    }
  });

  const pushResult = await sendPushToTokens({
    tokens: recipientDevices.map((device) => device.fcmToken),
    title: `🟢 ${senderName} is live`,
    body: "Tap to open Duo 🎙️",
    data: {
      type: "friend_live",
      groupId: input.groupId,
      senderUserId: input.senderUserId,
      deepLink: `walkie://group/${input.groupId}`
    }
  });

  await writeDeliveries(notificationEventId, recipientDevices, pushResult);

  await writeStatusEvent(input.groupId, input.senderUserId, "friend_live_notification_sent", {
    notificationEventId
  });

  return {
    notificationEventId,
    eventType: "friend_live",
    deduped: false,
    recipientUsers: recipientUserIds.length,
    targetDevices: recipientDevices.length,
    sent: pushResult.successCount,
    failed: pushResult.failureCount,
    skipped: recipientUserIds.length === 0 ? 1 : 0
  };
}

/** Notifies the caller that they were taken offline as a side effect of
 * presence rules (peer left, inactivity, usage cap, network loss) — not a
 * manual leave. Delivers to the caller's own devices so background / PiP
 * users see the transition. */
export async function sendGoneOfflineNotification(input: GoneOfflineInput) {
  await requireActiveUser(input.userId);
  await requireActiveGroup(input.groupId);
  await requireActiveGroupMember(input.groupId, input.userId);
  await requireActiveUserDevice(input.userId, input.deviceId);

  const now = nowSeconds();
  const dedupedEvent = await findRecentNotificationEvent({
    groupId: input.groupId,
    senderUserId: input.userId,
    eventType: "gone_offline",
    since: now - goneOfflineDedupeSeconds
  });

  if (dedupedEvent) {
    return {
      notificationEventId: dedupedEvent.notificationEventId,
      eventType: "gone_offline" as const,
      deduped: true,
      reason: input.reason,
      targetDevices: 0,
      sent: 0,
      failed: 0
    };
  }

  const copy = goneOfflineCopy[input.reason];
  const recipientDevices = await collectRecipientDevices([input.userId]);
  const notificationEventId = await createNotificationEvent({
    groupId: input.groupId,
    senderUserId: input.userId,
    eventType: "gone_offline",
    targetScope: "self",
    targetUserIds: [input.userId],
    createdAt: now,
    metadata: {
      reason: input.reason,
      deviceId: input.deviceId
    }
  });

  const pushResult = await sendAndroidDataPushes(
    recipientDevices.map((device) => ({
      token: device.fcmToken,
      data: {
        type: "gone_offline",
        groupId: input.groupId,
        reason: input.reason,
        title: copy.title,
        body: copy.body,
        deepLink: `walkie://group/${input.groupId}`
      }
    })),
    goneOfflineTtlMs
  );

  await writeDeliveries(notificationEventId, recipientDevices, pushResult);
  await writeStatusEvent(input.groupId, input.userId, "gone_offline_notification_sent", {
    notificationEventId,
    reason: input.reason
  });

  return {
    notificationEventId,
    eventType: "gone_offline" as const,
    deduped: false,
    reason: input.reason,
    targetDevices: recipientDevices.length,
    sent: pushResult.successCount,
    failed: pushResult.failureCount
  };
}

export async function sendNudgeNotification(input: NudgeInput) {
  await requireActiveUser(input.senderUserId);
  const group = await requireActiveGroup(input.groupId);
  await requireActiveGroupMember(input.groupId, input.senderUserId);

  if (input.targetScope === "single_friend") {
    if (!input.targetUserId) {
      throw new HttpError(400, "target_user_required", "targetUserId is required.");
    }
    await requireActiveGroupMember(input.groupId, input.targetUserId);
  }

  if (input.targetScope === "selected_friends") {
    const selected = uniqueRecipientIds(input.targetUserIds, input.senderUserId);
    if (selected.length === 0) {
      throw new HttpError(400, "target_users_required", "targetUserIds is required.");
    }
    for (const userId of selected) {
      await requireActiveGroupMember(input.groupId, userId);
    }
  }

  const now = nowSeconds();
  let recipientUserIds =
    input.targetScope === "single_friend"
      ? [input.targetUserId!].filter((userId) => userId !== input.senderUserId)
      : input.targetScope === "selected_friends"
        ? uniqueRecipientIds(input.targetUserIds, input.senderUserId)
        : await activeRecipientUserIds(input.groupId, input.senderUserId);
  const liveUserIds = new Set(
    await listInVoiceSessionUserIds(input.groupId)
  );
  recipientUserIds = recipientUserIds.filter((userId) => !liveUserIds.has(userId));
  await enforceNudgeRateLimits({
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    eventType: "nudge",
    targetUserIds: recipientUserIds
  });
  const senderName = await readDisplayName(input.senderUserId);
  const senderPhotoUrl = await readProfilePhotoUrl(input.senderUserId);
  const senderAvatarAsset = await readAvatarAsset(input.senderUserId);
  const recipientDevices = await collectRecipientDevices(recipientUserIds);
  const recipientNames = await readDisplayNames(recipientUserIds);
  const notificationEventId = await createNotificationEvent({
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    eventType: "nudge",
    targetScope: input.targetScope,
    targetUserIds: recipientUserIds,
    createdAt: now,
    metadata: {}
  });

  const baseUrl = config.PUBLIC_API_BASE_URL.replace(/\/$/, "");
  const ackUrl = `${baseUrl}/v1/nudges/${notificationEventId}/ack`;
  const pushResult = await sendAndroidDataPushes(
    recipientDevices.map((device) => ({
      token: device.fcmToken,
      data: {
        type: "nudge",
        eventId: notificationEventId,
        groupId: input.groupId,
        senderUserId: input.senderUserId,
        senderName,
        groupName: group.name,
        recipientUserId: device.userId,
        recipientName: recipientNames.get(device.userId)?.trim() || "your friend",
        ...(senderPhotoUrl ? { senderPhotoUrl } : {}),
        ...(senderAvatarAsset ? { senderAvatarAsset } : {}),
        responseUrl: `${baseUrl}/v1/groups/${input.groupId}/nudges/${notificationEventId}/respond`,
        ackUrl,
        deliveryToken: createAckTicket({
          eventId: notificationEventId,
          groupId: input.groupId,
          kind: "nudge",
          senderUserId: input.senderUserId,
          recipientUserId: device.userId,
          recipientName: recipientNames.get(device.userId)?.trim() || "your friend"
        }),
        deepLink: `walkie://group/${input.groupId}`
      }
    })),
    actionableNudgeTtlMs
  );

  await writeDeliveries(notificationEventId, recipientDevices, pushResult);

  // NOTE: Do NOT delete notificationEvents/{groupId}/{eventId} here.
  // respondToNudge needs the event record to validate the sender,
  // recipients, and event type when the recipient accepts/declines/snoozes.
  // The record is cleaned up naturally as new events push old ones out
  // of the rate-limiter window.

  await writeStatusEvent(input.groupId, input.senderUserId, "nudge_sent", {
    notificationEventId,
    targetScope: input.targetScope
  });

  return {
    notificationEventId,
    eventType: "nudge",
    rateLimited: false,
    recipientUserIds,
    recipientUsers: recipientUserIds.length,
    targetDevices: recipientDevices.length,
    sent: pushResult.successCount,
    failed: pushResult.failureCount,
    skipped: recipientUserIds.length === 0 ? 1 : 0
  };
}

const chatMessageTtlMs = chatUnreadTtlSeconds * 1000;
const chatNotifyMaxWords = 10;
const chatNotifyMaxChars = 240;

/** Fans out one data-only FCM per chat bubble so Android can show the
 * actual message text (and keep a WhatsApp-style conversation + reply). */
export async function sendChatMessageNotification(input: ChatMessageInput) {
  await requireActiveUser(input.senderUserId);
  const group = await requireActiveGroup(input.groupId);
  await requireActiveGroupMember(input.groupId, input.senderUserId);

  const senderName = await readDisplayName(input.senderUserId);
  const senderPhotoUrl = await readProfilePhotoUrl(input.senderUserId);
  const senderAvatarAsset = await readAvatarAsset(input.senderUserId);
  const messageText = sanitizeChatNotificationText(input.text);
  const messageId = input.messageId?.trim() || undefined;
  const recipientUserIds = await activeRecipientUserIds(input.groupId, input.senderUserId);
  const recipientDevices = await collectRecipientDevices(recipientUserIds);
  const notificationEventId = await createNotificationEvent({
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    eventType: "chat_message",
    targetScope: "all_friends",
    targetUserIds: recipientUserIds,
    createdAt: nowSeconds(),
    metadata: messageId ? { messageId } : {}
  });

  const unreadByUser = new Map<string, number>();
  for (const userId of recipientUserIds) {
    unreadByUser.set(userId, await bumpChatUnread(input.groupId, userId));
  }

  const baseUrl = config.PUBLIC_API_BASE_URL.replace(/\/$/, "");
  const notifyUrl = `${baseUrl}/v1/groups/${input.groupId}/chat-messages/notify`;
  const title = `💬 ${senderName}`;
  const body = messageText ?? `${senderName} sent a message`;
  const pushResult = await sendAndroidDataPushes(
    recipientDevices.map((device) => {
      const count = unreadByUser.get(device.userId) ?? 1;
      return {
        token: device.fcmToken,
        data: {
          type: "chat_message",
          groupId: input.groupId,
          groupName: group.name,
          senderUserId: input.senderUserId,
          senderName,
          ...(senderPhotoUrl ? { senderPhotoUrl } : {}),
          ...(senderAvatarAsset ? { senderAvatarAsset } : {}),
          ...(messageId ? { messageId } : {}),
          ...(messageText ? { messageText } : {}),
          unreadCount: String(count),
          title,
          body,
          notifyUrl,
          deepLink: `walkie://group/${input.groupId}`
        }
      };
    }),
    chatMessageTtlMs
  );

  await writeDeliveries(notificationEventId, recipientDevices, pushResult);

  return {
    notificationEventId,
    eventType: "chat_message" as const,
    recipientUsers: recipientUserIds.length,
    targetDevices: recipientDevices.length,
    sent: pushResult.successCount,
    failed: pushResult.failureCount,
    skipped: recipientUserIds.length === 0 ? 1 : 0
  };
}

async function bumpChatUnread(groupId: string, userId: string) {
  const ref = getRealtimeDatabase().ref(`chatUnread/${groupId}/${userId}`);
  const now = nowSeconds();
  const result = await ref.transaction((current: unknown) => nextChatUnread(current, now));
  const value = result.snapshot.val();
  if (isRecord(value) && typeof value.count === "number" && value.count > 0) {
    return value.count;
  }
  return 1;
}

async function activeRecipientUserIds(groupId: string, senderUserId: string) {
  const snapshot = await getRealtimeDatabase().ref(`groupMembers/${groupId}`).get();
  if (!snapshot.exists() || !isRecord(snapshot.val())) return [];

  const memberIds = Object.entries(snapshot.val() as Record<string, unknown>)
    .filter(([userId, value]) => {
      return userId !== senderUserId && isRecord(value) && value.memberState === "active";
    })
    .map(([userId]) => userId);

  // Drop accounts that were deleted (users/{uid} gone). Uninstalled-but-still-
  // registered accounts keep their users record and remain eligible.
  return filterActiveAccountUserIds(memberIds);
}

async function collectRecipientDevices(userIds: string[]) {
  const db = getRealtimeDatabase();
  const devices: RecipientDevice[] = [];

  for (const userId of userIds) {
    const snapshot = await db.ref(`userDevices/${userId}`).get();
    if (!snapshot.exists() || !isRecord(snapshot.val())) continue;

    for (const [deviceId, value] of Object.entries(snapshot.val() as Record<string, unknown>)) {
      if (!isRecord(value)) continue;
      if (value.deviceState !== "active") continue;
      const fcmToken = value.fcmToken?.toString();
      if (!fcmToken) continue;

      devices.push({
        userId,
        deviceId,
        fcmToken
      });
    }
  }

  return devices;
}

async function createNotificationEvent(input: {
  groupId: string;
  senderUserId: string;
  eventType: string;
  targetScope: string;
  targetUserIds: string[];
  createdAt: number;
  metadata: Record<string, unknown>;
}) {
  const ref = getRealtimeDatabase().ref(`notificationEvents/${input.groupId}`).push();
  const notificationEventId = ref.key;
  if (!notificationEventId) {
    throw new HttpError(500, "notification_event_id_failed", "Failed to allocate notification event id.");
  }

  await ref.set({
    notificationEventId,
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    eventType: input.eventType,
    targetScope: input.targetScope,
    targetUserIds: input.targetUserIds,
    createdAt: input.createdAt,
    metadata: input.metadata
  });

  return notificationEventId;
}

async function writeDeliveries(
  notificationEventId: string,
  recipientDevices: RecipientDevice[],
  pushResult: {
    successCount: number;
    failureCount: number;
    responses: Array<{ success: boolean; messageId?: string; error?: unknown }>;
  }
) {
  const updates: Record<string, unknown> = {};
  const now = nowSeconds();

  recipientDevices.forEach((device, index) => {
    const response = pushResult.responses[index];
    const deliveryId = `${device.userId}_${device.deviceId}`;
    updates[`notificationDeliveries/${notificationEventId}/${deliveryId}`] = {
      notificationEventId,
      userId: device.userId,
      deviceId: device.deviceId,
      fcmTokenTail: device.fcmToken.slice(-8),
      deliveryState: response?.success ? "sent" : "failed",
      fcmMessageId: response?.messageId ?? null,
      errorCode: response?.error ? String(response.error) : null,
      attemptedAt: now
    };
    if (isPermanentMessagingTargetError(response?.error)) {
      updates[`userDevices/${device.userId}/${device.deviceId}/fcmToken`] = null;
      updates[`userDevices/${device.userId}/${device.deviceId}/registrationInvalidatedAt`] = now;
    }
  });

  if (Object.keys(updates).length > 0) {
    await getRealtimeDatabase().ref().update(updates);
  }
}

async function writeStatusEvent(
  groupId: string,
  userId: string,
  eventType: string,
  metadata: Record<string, unknown>
) {
  const ref = getRealtimeDatabase().ref(`statusEvents/${groupId}`).push();
  const eventId = ref.key;
  if (!eventId) return;

  await ref.set({
    eventId,
    groupId,
    userId,
    eventType,
    metadata,
    createdAt: nowSeconds()
  });
}

async function readDisplayName(userId: string) {
  const snapshot = await getRealtimeDatabase().ref(`users/${userId}/displayName`).get();
  return snapshot.val()?.toString() || "Someone";
}

async function readDisplayNames(userIds: string[]): Promise<Map<string, string>> {
  const names = new Map<string, string>();
  await Promise.all(
    userIds.map(async (userId) => {
      names.set(userId, await readDisplayName(userId));
    })
  );
  return names;
}

function sanitizeChatNotificationText(raw: string | undefined): string | undefined {
  if (typeof raw !== "string") return undefined;
  const normalized = raw.trim().replace(/\s+/g, " ");
  if (!normalized) return undefined;
  const words = normalized.split(" ").slice(0, chatNotifyMaxWords);
  return words.join(" ").slice(0, chatNotifyMaxChars);
}

async function readProfilePhotoUrl(userId: string): Promise<string | undefined> {
  const snapshot = await getRealtimeDatabase()
    .ref(`users/${userId}/profilePhotoUrl`)
    .get();
  const url = snapshot.val()?.toString()?.trim();
  return url || undefined;
}

async function readAvatarAsset(userId: string): Promise<string | undefined> {
  const snapshot = await getRealtimeDatabase()
    .ref(`users/${userId}/avatarAsset`)
    .get();
  const value = snapshot.val()?.toString()?.trim();
  if (!value) return undefined;
  if (
    !value.startsWith("assets/avatars/") &&
    !value.startsWith("assets/avatars2/")
  ) {
    return undefined;
  }
  return value;
}

async function findRecentNotificationEvent(input: {
  groupId: string;
  senderUserId: string;
  eventType: string;
  since: number;
}) {
  const events = await listRecentNotificationEvents(input);
  return events[0] ?? null;
}

async function listRecentNotificationEvents(input: {
  groupId: string;
  senderUserId: string;
  eventType: string;
  since: number;
}) {
  const snapshot = await getRealtimeDatabase().ref(`notificationEvents/${input.groupId}`).get();
  if (!snapshot.exists() || !isRecord(snapshot.val())) return [];

  return Object.values(snapshot.val() as Record<string, unknown>)
    .filter(isNotificationEvent)
    .filter((event) => {
      return (
        event.senderUserId === input.senderUserId &&
        event.eventType === input.eventType &&
        event.createdAt >= input.since
      );
    })
    .sort((a, b) => b.createdAt - a.createdAt);
}

type NotificationEventRecord = {
  notificationEventId: string;
  senderUserId: string;
  eventType: string;
  targetUserIds: string[];
  createdAt: number;
};

function isNotificationEvent(value: unknown): value is NotificationEventRecord {
  if (!isRecord(value)) return false;

  return (
    typeof value.notificationEventId === "string" &&
    typeof value.senderUserId === "string" &&
    typeof value.eventType === "string" &&
    typeof value.createdAt === "number" &&
    Array.isArray(value.targetUserIds)
  );
}

function uniqueRecipientIds(userIds: string[] | undefined, senderUserId: string) {
  return [...new Set(userIds ?? [])].filter((userId) => userId !== senderUserId);
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
