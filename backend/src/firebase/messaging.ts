import type { Message } from "firebase-admin/messaging";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "../logger.js";
import { requireFirebaseAdminApp } from "./adminApp.js";

export type PushPayload = {
  tokens: string[];
  title: string;
  body: string;
  data?: Record<string, string>;
};

export async function sendPushToTokens(payload: PushPayload) {
  if (payload.tokens.length === 0) {
    logEmptyBatch("notification");
    return {
      successCount: 0,
      failureCount: 0,
      responses: []
    };
  }

  const analyticsLabel = analyticsLabelFor(payload.data?.type, "notification");
  const messages: Message[] = payload.tokens.map((target) => ({
    ...messageTarget(target),
    notification: {
      title: payload.title,
      body: payload.body
    },
    data: payload.data,
    fcmOptions: { analyticsLabel },
    android: {
      priority: "high",
      fcmOptions: { analyticsLabel },
      notification: {
        channelId: "walkie_alerts_v2",
        icon: "ic_notification_app",
        color: "#F8BE03"
      }
    }
  }));

  return sendMessagesWithDiagnostics(messages, "notification");
}

export type AndroidDataPush = {
  token: string;
  data: Record<string, string>;
};

export async function sendAndroidDataPushes(pushes: AndroidDataPush[], ttlMs: number) {
  if (pushes.length === 0) {
    logEmptyBatch("android-data");
    return {
      successCount: 0,
      failureCount: 0,
      responses: []
    };
  }

  const messages: Message[] = pushes.map((push) => {
    const analyticsLabel = analyticsLabelFor(push.data.type, "android-data");
    return {
      ...messageTarget(push.token),
      data: push.data,
      fcmOptions: { analyticsLabel },
      android: {
        priority: "high" as const,
        ttl: ttlMs,
        fcmOptions: { analyticsLabel }
      }
    };
  });

  return sendMessagesWithDiagnostics(messages, "android-data");
}

/** FCM Messaging Reports only count data messages that carry an analytics label.
 * Labels must match ^[a-zA-Z0-9-_.~%]{1,50}$; keep under 100 unique/day. */
function analyticsLabelFor(type: string | undefined, fallback: string): string {
  const raw = (type?.trim() || fallback).slice(0, 50);
  const sanitized = raw.replace(/[^a-zA-Z0-9-_.~%]/g, "_");
  return sanitized.length > 0 ? sanitized : fallback;
}

function logEmptyBatch(operation: string) {
  logger.warn(
    {
      checkpoint: "FCM-BE-W0",
      category: "expected",
      operation,
      targetCount: 0
    },
    "skipping Firebase Cloud Messaging batch because no target devices were found"
  );
}

function messageTarget(target: string): { fid: string } | { token: string } {
  // Firebase Installation IDs are 22 URL-safe characters and currently begin
  // with c, d, e, or f. Retain token support while older app installs migrate.
  return /^[cdef][A-Za-z0-9_-]{21}$/.test(target) ? { fid: target } : { token: target };
}

export function isPermanentMessagingTargetError(error: unknown) {
  if (typeof error !== "object" || error === null || !("code" in error)) return false;
  const code = String(error.code);
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token" ||
    // FID-based sends (current Android installs) use this code when the
    // Installation ID is gone or revoked — clear it so we stop retrying.
    code === "messaging/installation-id-not-registered"
  );
}

async function sendMessagesWithDiagnostics(messages: Message[], operation: string) {
  const fidCount = messages.filter((message) => "fid" in message).length;
  const legacyTokenCount = messages.filter((message) => "token" in message).length;
  logger.info(
    {
      checkpoint: "FCM-BE-01",
      category: "expected",
      operation,
      targetCount: messages.length,
      fidCount,
      legacyTokenCount
    },
    "sending Firebase Cloud Messaging batch"
  );

  try {
    const result = await getMessaging(requireFirebaseAdminApp()).sendEach(messages);
    const failureCodes = result.responses
      .filter((response) => !response.success)
      .map((response) => response.error?.code ?? "unknown");
    const log = result.failureCount > 0 ? logger.warn.bind(logger) : logger.info.bind(logger);
    log(
      {
        checkpoint: result.failureCount > 0 ? "FCM-BE-W1" : "FCM-BE-02",
        category: result.failureCount > 0 ? "unexpected" : "expected",
        operation,
        successCount: result.successCount,
        failureCount: result.failureCount,
        failureCodes
      },
      "Firebase Cloud Messaging batch completed"
    );
    return result;
  } catch (error) {
    const diagnostic =
      error instanceof Error
        ? {
            name: error.name,
            message: error.message,
            code: "code" in error ? String(error.code) : undefined
          }
        : { name: typeof error, message: String(error) };
    logger.error(
      {
        checkpoint: "FCM-BE-E1",
        category: "unexpected",
        operation,
        error: diagnostic
      },
      "Firebase Cloud Messaging batch call failed"
    );
    throw error;
  }
}
