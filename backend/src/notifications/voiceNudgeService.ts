import { randomUUID } from "node:crypto";
import { getRealtimeDatabase } from "../firebase/database.js";
import { sendAndroidDataPushes } from "../firebase/messaging.js";
import {
  getVoiceNudgeBucket,
  createVoiceNudgeSignedReadUrl,
  createVoiceNudgeSignedWriteUrl,
  voiceNudgeUploadContentType
} from "../firebase/storage.js";
import { config } from "../config.js";
import { HttpError } from "../http/httpError.js";
import { logger } from "../logger.js";
import { listInVoiceSessionUserIds, requireActiveGroup } from "../groups/groupService.js";
import { createAckTicket } from "./nudgeDeliveryService.js";
import {
  createUploadTicket,
  maxVoiceNudgeBytes,
  validateVoiceNudgeAudio,
  validateVoiceNudgeDuration,
  verifyUploadTicket,
  type UploadTicket
} from "./voiceNudgeValidation.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type NudgeTarget = {
  targetScope: "single_friend" | "all_friends" | "selected_friends";
  targetUserId?: string;
};

type RecipientDevice = {
  userId: string;
  deviceId: string;
  fcmToken: string;
  /** Recipient's display name — used to embed in the delivery ack ticket so
   *  the sender-side confirmation can read "playing on <name>'s device". */
  displayName?: string;
};

export type CreateVoiceNudgeInput = NudgeTarget & {
  groupId: string;
  senderUserId: string;
  audio: Buffer;
  durationMs: number;
};

export type InitiateVoiceNudgeUploadInput = NudgeTarget & {
  groupId: string;
  senderUserId: string;
  durationMs: number;
  recipientDevices: RecipientDevice[];
  senderName: string;
};

export type CompleteVoiceNudgeUploadInput = {
  uploadTicket: string;
};

export type SendRingNudgeInput = NudgeTarget & {
  groupId: string;
  senderUserId: string;
  durationSeconds: 3 | 6 | 9;
  recipientDevices: RecipientDevice[];
  senderName: string;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const voiceNudgeMediaTtlSeconds = 10 * 60;
const voiceNudgeUploadUrlTtlSeconds = 5 * 60;
const voiceNudgePushTtlMs = 60 * 1000;
const ringNudgePushTtlMs = 30 * 1000;

// ---------------------------------------------------------------------------
// initiateVoiceNudgeUpload — ZERO RTDB calls
// ---------------------------------------------------------------------------

export async function initiateVoiceNudgeUpload(input: InitiateVoiceNudgeUploadInput) {
  validateVoiceNudgeDuration(input.durationMs);

  if (!input.recipientDevices || input.recipientDevices.length === 0) {
    throw new HttpError(400, "no_recipient_devices", "At least one recipient device is required.");
  }

  const eventId = randomUUID().replace(/-/g, "");
  const now = nowSeconds();
  const expiresAt = now + voiceNudgeMediaTtlSeconds;
  const uploadExpiresAt = now + voiceNudgeUploadUrlTtlSeconds;
  const storagePath = `voiceNudges/${eventId}.m4a`;

  let signedWrite: Awaited<ReturnType<typeof createVoiceNudgeSignedWriteUrl>>;
  try {
    signedWrite = await createVoiceNudgeSignedWriteUrl(storagePath, uploadExpiresAt * 1000);
  } catch (error) {
    logger.error(
      {
        checkpoint: "VOICE-NUDGE-BE-E1",
        category: "unexpected",
        eventId,
        storagePath,
        error: describeError(error)
      },
      "voice nudge signed write URL generation failed"
    );
    throw error;
  }

  const recipientUserIds = [
    ...new Set(input.recipientDevices.map((d) => d.userId))
  ].filter((uid) => uid !== input.senderUserId);

  const ticket = createUploadTicket({
    eventId,
    groupId: input.groupId,
    senderUserId: input.senderUserId,
    targetScope: input.targetScope,
    targetUserId: input.targetUserId,
    recipientDevices: input.recipientDevices,
    recipientUserIds,
    senderName: input.senderName,
    durationMs: input.durationMs,
    storagePath,
    expiresAt,
    uploadExpiresAt
  });

  logger.info(
    {
      checkpoint: "VOICE-NUDGE-BE-01",
      category: "expected",
      eventId,
      groupId: input.groupId,
      durationMs: input.durationMs,
      uploadMode: "signed_write_url__rtdb_free",
      uploadExpiresAt,
      recipientUsers: recipientUserIds.length,
      targetDevices: input.recipientDevices.length
    },
    "voice nudge signed write URL issued; all context sealed in upload ticket (zero RTDB)"
  );

  return {
    notificationEventId: eventId,
    uploadUrl: signedWrite.uploadUrl,
    storagePath,
    contentType: signedWrite.contentType,
    requiredHeaders: signedWrite.requiredHeaders,
    maxBytes: maxVoiceNudgeBytes,
    uploadExpiresAt,
    expiresAt,
    uploadTicket: ticket
  };
}

// ---------------------------------------------------------------------------
// completeVoiceNudgeUpload — ZERO RTDB calls
// ---------------------------------------------------------------------------

export async function completeVoiceNudgeUpload(input: CompleteVoiceNudgeUploadInput) {
  const ticket = verifyUploadTicket(input.uploadTicket);
  const now = nowSeconds();
  if (ticket.uploadExpiresAt < now) {
    throw new HttpError(410, "voice_nudge_upload_expired", "Voice nudge upload has expired.");
  }
  return dispatchVoiceNudgeFromContext(ticket);
}

/** Raw-context dispatch — used by the legacy RTDB fallback path in routes. */
export async function completeVoiceNudgeUploadWithContext(ctx: {
  eventId: string;
  groupId: string;
  senderUserId: string;
  senderName: string;
  durationMs: number;
  expiresAt: number;
  storagePath: string;
  recipientUserIds: string[];
  recipientDevices: RecipientDevice[];
}) {
  return dispatchVoiceNudgeFromContext(ctx);
}

async function dispatchVoiceNudgeFromContext(ctx: {
  eventId: string;
  groupId: string;
  senderUserId: string;
  senderName: string;
  durationMs: number;
  expiresAt: number;
  storagePath: string;
  recipientUserIds: string[];
  recipientDevices: RecipientDevice[];
}) {
  const [liveParticipantUserIds, group, audioBytes] = await Promise.all([
    listInVoiceSessionUserIds(ctx.groupId),
    requireActiveGroup(ctx.groupId),
    verifyClientUploadedVoiceObject(ctx.eventId, ctx.storagePath)
  ]);
  const liveUserIds = new Set(liveParticipantUserIds);
  const recipientDevices = ctx.recipientDevices.filter(
    (device) => device.userId !== ctx.senderUserId && !liveUserIds.has(device.userId)
  );
  const recipientUserIds = [...new Set(recipientDevices.map((device) => device.userId))];

  logger.info(
    {
      checkpoint: "VOICE-NUDGE-BE-02",
      category: "expected",
      eventId: ctx.eventId,
      storagePath: ctx.storagePath,
      audioBytes,
      uploadMode: "signed_write_url__rtdb_free"
    },
    "voice nudge audio verified in Cloud Storage after client direct upload"
  );

  const file = getVoiceNudgeBucket().file(ctx.storagePath);

  if (recipientDevices.length === 0) {
    logger.warn(
      {
        checkpoint: "VOICE-NUDGE-BE-W1",
        category: "expected",
        eventId: ctx.eventId,
        reason: "no_recipients"
      },
      "voice nudge has no active recipient devices, purging Cloud Storage object immediately"
    );
    await file.delete({ ignoreNotFound: true }).catch(() => undefined);
    return nudgeResult(ctx.eventId, ctx.recipientUserIds.length, 0, 0, 0);
  }

  // Independent post-upload work runs in parallel instead of serially: sign
  // the read URL, fetch the sender's profile photo + avatar, and write the
  // respond-event record (non-fatal). Previously each awaited before the FCM
  // push, adding several serial RTDB/GCS round trips to sender-visible latency.
  const baseUrl = config.PUBLIC_API_BASE_URL.replace(/\/$/, "");
  const responseUrl = `${baseUrl}/v1/groups/${ctx.groupId}/nudges/${ctx.eventId}/respond`;
  const signedAudioUrlPromise = createVoiceNudgeSignedReadUrl(
    ctx.storagePath,
    ctx.expiresAt * 1000
  ).catch(async (error) => {
    logger.error(
      {
        checkpoint: "VOICE-NUDGE-BE-E1",
        category: "unexpected",
        eventId: ctx.eventId,
        storagePath: ctx.storagePath,
        error: describeError(error)
      },
      "voice nudge signed read URL generation failed, rolling back Cloud Storage object"
    );
    await file.delete({ ignoreNotFound: true }).catch(() => undefined);
    throw error;
  });

  const [signedAudioUrl, senderPhotoUrl, senderAvatarAsset] = await Promise.all([
    signedAudioUrlPromise,
    readProfilePhotoUrl(ctx.senderUserId),
    readAvatarAsset(ctx.senderUserId),
    writeNudgeNotificationEvent({
      groupId: ctx.groupId,
      eventId: ctx.eventId,
      senderUserId: ctx.senderUserId,
      eventType: "voice_nudge",
      targetScope: "all_friends",
      targetUserIds: recipientUserIds,
      createdAt: nowSeconds(),
      responseUrl,
      senderName: ctx.senderName
    })
  ]);

  const ackUrl = `${baseUrl}/v1/nudges/${ctx.eventId}/ack`;
  const pushResult = await sendAndroidDataPushes(
    recipientDevices.map((device) => ({
      token: device.fcmToken,
      data: {
        type: "voice_nudge",
        eventId: ctx.eventId,
        groupId: ctx.groupId,
        senderUserId: ctx.senderUserId,
        senderName: ctx.senderName,
        groupName: group.name,
        recipientUserId: device.userId,
        recipientName: device.displayName?.trim() || "your friend",
        ...(senderPhotoUrl ? { senderPhotoUrl } : {}),
        ...(senderAvatarAsset ? { senderAvatarAsset } : {}),
        durationMs: String(ctx.durationMs),
        expiresAt: String(ctx.expiresAt),
        audioUrl: signedAudioUrl,
        responseUrl,
        ackUrl,
        deliveryToken: createAckTicket({
          eventId: ctx.eventId,
          groupId: ctx.groupId,
          kind: "voice_nudge",
          senderUserId: ctx.senderUserId,
          recipientUserId: device.userId,
          recipientName: device.displayName?.trim() || "your friend"
        })
      }
    })),
    voiceNudgePushTtlMs
  );

  logger.info(
    {
      checkpoint: "VOICE-NUDGE-BE-03",
      category: "expected",
      eventId: ctx.eventId,
      audioBytes,
      targetDevices: recipientDevices.length,
      sent: pushResult.successCount,
      failed: pushResult.failureCount,
      deliveryMode: "signed_url",
      uploadMode: "signed_write_url__rtdb_free",
      rtdbCalls: 0
    },
    "voice nudge dispatched via FCM (zero RTDB calls)"
  );

  return {
    ...nudgeResult(
      ctx.eventId,
      recipientUserIds.length,
      recipientDevices.length,
      pushResult.successCount,
      pushResult.failureCount
    ),
    recipientUserIds
  };
}

// ---------------------------------------------------------------------------
// verifyClientUploadedVoiceObject — GCS only, no RTDB
// ---------------------------------------------------------------------------

async function verifyClientUploadedVoiceObject(eventId: string, storagePath: string) {
  const file = getVoiceNudgeBucket().file(storagePath);

  let metadata: Record<string, unknown>;
  try {
    [metadata] = (await file.getMetadata()) as unknown as [Record<string, unknown>];
  } catch (error) {
    if (isHttpErrorCode(error, 404)) {
      throw new HttpError(
        409,
        "voice_nudge_upload_missing",
        "Voice nudge audio has not been uploaded yet."
      );
    }
    throw error;
  }
  const size = Number((metadata as { size?: number }).size ?? 0);
  if (!Number.isFinite(size) || size <= 0 || size > maxVoiceNudgeBytes) {
    await file.delete({ ignoreNotFound: true }).catch(() => undefined);
    throw new HttpError(
      413,
      "voice_nudge_too_large",
      `Voice nudge audio must not exceed ${maxVoiceNudgeBytes} bytes.`
    );
  }

  const [header] = await file.download({ start: 0, end: Math.min(11, size - 1) });
  if (header.length < 12 || header.subarray(4, 8).toString("ascii") !== "ftyp") {
    await file.delete({ ignoreNotFound: true }).catch(() => undefined);
    throw new HttpError(400, "invalid_voice_nudge_audio", "Voice nudge must be an M4A file.");
  }

  logger.info(
    {
      checkpoint: "VOICE-NUDGE-BE-02A",
      category: "expected",
      eventId,
      storagePath,
      audioBytes: size,
      headerCheckBytes: header.length
    },
    "voice nudge client upload verified (metadata + ftyp header)"
  );

  return size;
}

// ---------------------------------------------------------------------------
// sendRingNudge
// ---------------------------------------------------------------------------

export async function sendRingNudge(input: SendRingNudgeInput) {
  const eventId = randomUUID().replace(/-/g, "");

  if (!input.recipientDevices || input.recipientDevices.length === 0) {
    return nudgeResult(eventId, 0, 0, 0, 0);
  }

  const now = nowSeconds();
  const [group, liveIds, suppressionSnapshot] = await Promise.all([
    requireActiveGroup(input.groupId),
    listInVoiceSessionUserIds(input.groupId),
    getRealtimeDatabase().ref(`ringSuppressions/${input.groupId}`).get()
  ]);
  const liveUserIds = new Set(liveIds);
  const suppressions = isRecord(suppressionSnapshot.val())
    ? suppressionSnapshot.val() as Record<string, unknown>
    : {};
  const recipientDevices = input.recipientDevices.filter((device) => {
    if (device.userId === input.senderUserId || liveUserIds.has(device.userId)) return false;
    const record = suppressions[device.userId];
    return !isRecord(record) || Number(record.suppressedUntil ?? 0) <= now;
  });
  const recipientUserIds = [...new Set(recipientDevices.map((d) => d.userId))];
  if (recipientDevices.length === 0 && input.recipientDevices.length > 0) {
    throw new HttpError(
      429,
      "nudge_rate_limited",
      "Ring is temporarily unavailable for the selected recipient."
    );
  }

  // Write a lightweight notification event so the respond-to-nudge endpoint
  // can validate ring-nudge responses and notification action buttons work.
  const baseUrl = config.PUBLIC_API_BASE_URL.replace(/\/$/, "");
  const responseUrl = `${baseUrl}/v1/groups/${input.groupId}/nudges/${eventId}/respond`;
  await writeNudgeNotificationEvent({
    groupId: input.groupId,
    eventId,
    senderUserId: input.senderUserId,
    eventType: "ring_nudge",
    targetScope: input.targetScope,
    targetUserId: input.targetUserId,
    targetUserIds: recipientUserIds,
    createdAt: now,
    responseUrl,
    senderName: input.senderName
  });

  const ackUrl = `${baseUrl}/v1/nudges/${eventId}/ack`;
  const senderPhotoUrl = await readProfilePhotoUrl(input.senderUserId);
  const senderAvatarAsset = await readAvatarAsset(input.senderUserId);
  const pushResult = await sendAndroidDataPushes(
    recipientDevices.map((device) => ({
      token: device.fcmToken,
      data: {
        type: "ring_nudge",
        eventId,
        groupId: input.groupId,
        senderUserId: input.senderUserId,
        senderName: input.senderName,
        groupName: group.name,
        recipientUserId: device.userId,
        recipientName: device.displayName?.trim() || "your friend",
        ...(senderPhotoUrl ? { senderPhotoUrl } : {}),
        ...(senderAvatarAsset ? { senderAvatarAsset } : {}),
        durationMs: String(input.durationSeconds * 1000),
        responseUrl,
        ackUrl,
        deliveryToken: createAckTicket({
          eventId,
          groupId: input.groupId,
          kind: "ring_nudge",
          senderUserId: input.senderUserId,
          recipientUserId: device.userId,
          recipientName: device.displayName?.trim() || "your friend"
        })
      }
    })),
    ringNudgePushTtlMs
  );

  return {
    ...nudgeResult(
      eventId,
      recipientUserIds.length,
      recipientDevices.length,
      pushResult.successCount,
      pushResult.failureCount
    ),
    recipientUserIds
  };
}

// ===================================================================
// DEPRECATED — kept only so route imports don't break.
// ===================================================================

/** @deprecated Use initiateVoiceNudgeUpload + completeVoiceNudgeUpload instead. */
export async function createVoiceNudge(input: CreateVoiceNudgeInput) {
  validateVoiceNudgeAudio(input.audio, input.durationMs);
  const eventId = randomUUID().replace(/-/g, "");
  const now = nowSeconds();
  const expiresAt = now + voiceNudgeMediaTtlSeconds;
  const storagePath = `voiceNudges/${eventId}.m4a`;
  const file = getVoiceNudgeBucket().file(storagePath);

  logger.info(
    {
      checkpoint: "VOICE-NUDGE-BE-01",
      category: "expected",
      eventId,
      audioBytes: input.audio.length,
      durationMs: input.durationMs,
      uploadMode: "backend_proxy_deprecated"
    },
    "voice nudge upload via legacy proxy (deprecated)"
  );

  await file.save(input.audio, {
    resumable: false,
    contentType: voiceNudgeUploadContentType,
    metadata: {
      cacheControl: "private, no-store, max-age=0",
      metadata: { eventId, expiresAt: String(expiresAt) }
    }
  });

  const signedUrl = await createVoiceNudgeSignedReadUrl(storagePath, expiresAt * 1000);
  return { notificationEventId: eventId, storagePath, signedUrl, legacy: true };
}

/** @deprecated Audio is delivered via signed URL in the FCM payload directly. */
export async function resolveVoiceNudgeAudioRedirect(_eventId: string, _token: string) {
  throw new HttpError(
    410,
    "voice_nudge_audio_deprecated",
    "Audio redirect endpoint is deprecated. Use the signed URL from the FCM payload."
  );
}

/** @deprecated Delivery tracking is managed client-side via RTDB directly. */
export async function acknowledgeVoiceNudge(
  _eventId: string,
  _token: string,
  _status: "played" | "failed"
) {
  return { eventId: _eventId, status: _status, ack: "client_only" };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function nudgeResult(
  notificationEventId: string,
  recipientUsers: number,
  targetDevices: number,
  sent: number,
  failed: number
) {
  return {
    notificationEventId,
    recipientUsers,
    targetDevices,
    sent,
    failed,
    skipped: recipientUsers === 0 || targetDevices === 0 ? 1 : 0,
    rtdbCalls: 0
  };
}

/**
 * Writes a minimal notification event to RTDB so the respond-to-nudge
 * endpoint can validate ring/voice nudge responses (which are otherwise
 * RTDB-free for the send path). This is a single small write — far less
 * overhead than the legacy full-state approach.
 */
async function writeNudgeNotificationEvent(input: {
  groupId: string;
  eventId: string;
  senderUserId: string;
  eventType: "ring_nudge" | "voice_nudge";
  targetScope: "single_friend" | "all_friends" | "selected_friends";
  targetUserId?: string;
  targetUserIds: string[];
  createdAt: number;
  responseUrl: string;
  senderName: string;
}) {
  try {
    const targetUserIds = input.targetUserId
      ? [input.targetUserId].filter((uid) => uid !== input.senderUserId)
      : input.targetUserIds;
    await getRealtimeDatabase().ref(`notificationEvents/${input.groupId}/${input.eventId}`).set({
      notificationEventId: input.eventId,
      groupId: input.groupId,
      senderUserId: input.senderUserId,
      eventType: input.eventType,
      targetScope: input.targetScope,
      targetUserIds,
      createdAt: input.createdAt,
      metadata: { responseUrl: input.responseUrl, senderName: input.senderName }
    });
    logger.info(
      {
        checkpoint: "NUDGE-EVENT-BE-01",
        category: "expected",
        eventId: input.eventId,
        eventType: input.eventType,
        targetUserIds: targetUserIds.length
      },
      "notification event written for ring/voice nudge response validation"
    );
  } catch (error) {
    // Non-fatal — the nudge still delivers even if the response record fails.
    logger.warn(
      {
        checkpoint: "NUDGE-EVENT-BE-W1",
        category: "expected",
        eventId: input.eventId,
        eventType: input.eventType,
        error: describeError(error)
      },
      "failed to write notification event for ring/voice nudge; respond actions may not work"
    );
  }
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

async function readProfilePhotoUrl(userId: string): Promise<string | undefined> {
  try {
    const snapshot = await getRealtimeDatabase()
      .ref(`users/${userId}/profilePhotoUrl`)
      .get();
    const url = snapshot.val()?.toString()?.trim();
    return url || undefined;
  } catch {
    return undefined;
  }
}

async function readAvatarAsset(userId: string): Promise<string | undefined> {
  try {
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
  } catch {
    return undefined;
  }
}

function describeError(error: unknown) {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      code: "code" in error ? String((error as { code: unknown }).code) : undefined
    };
  }
  return { name: typeof error, message: String(error) };
}

function isHttpErrorCode(error: unknown, code: number): boolean {
  if (typeof error !== "object" || error === null) return false;
  return (
    Number((error as { code?: unknown }).code) === code ||
    Number((error as { status?: unknown }).status) === code
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
