import { getRealtimeDatabase } from "../firebase/database.js";
import {
  isPermanentMessagingTargetError,
  sendPushToTokens
} from "../firebase/messaging.js";
import { logger } from "../logger.js";
import {
  hasAnyGroups,
  isDueForReminder,
  isIdleNewUserCandidate,
  nextReminderState,
  noGroupReminderCopy,
  parseReminderState,
  type NoGroupReminderState
} from "./noGroupReminderEligibility.js";

type RecipientDevice = {
  userId: string;
  deviceId: string;
  fcmToken: string;
};

export type NoGroupReminderRunResult = {
  scannedUsers: number;
  eligible: number;
  sent: number;
  skippedNoToken: number;
  skippedHasGroups: number;
  skippedNotDue: number;
  failed: number;
};

/**
 * Daily engagement job: push "create a group & invite friends" to logged-in
 * new users who still have zero groups and have not opened the app recently.
 *
 * Notification-payload FCM opens the launcher activity on tap (no deep link).
 */
export async function runNoGroupReminders(
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<NoGroupReminderRunResult> {
  const db = getRealtimeDatabase();
  const result: NoGroupReminderRunResult = {
    scannedUsers: 0,
    eligible: 0,
    sent: 0,
    skippedNoToken: 0,
    skippedHasGroups: 0,
    skippedNotDue: 0,
    failed: 0
  };

  const usersSnap = await db.ref("users").get();
  if (!isRecord(usersSnap.val())) {
    logger.info(
      { checkpoint: "NO-GROUP-REM-01", ...result },
      "no-group reminder job: no users found"
    );
    return result;
  }

  const users = usersSnap.val() as Record<string, unknown>;
  for (const [userId, rawUser] of Object.entries(users)) {
    result.scannedUsers += 1;
    if (!isRecord(rawUser)) continue;
    if (!isIdleNewUserCandidate(rawUser, nowSeconds)) continue;

    const groupsSnap = await db.ref(`userGroups/${userId}`).get();
    if (hasAnyGroups(groupsSnap.val())) {
      result.skippedHasGroups += 1;
      continue;
    }

    const stateSnap = await db.ref(`userEngagement/${userId}/noGroupReminder`).get();
    const state = parseReminderState(stateSnap.val());
    if (!isDueForReminder(state, nowSeconds)) {
      result.skippedNotDue += 1;
      continue;
    }

    result.eligible += 1;
    const devices = await collectActiveDevices(userId);
    if (devices.length === 0) {
      result.skippedNoToken += 1;
      continue;
    }

    const sent = await sendReminderToDevices(devices, state, nowSeconds);
    if (sent) {
      result.sent += 1;
    } else {
      result.failed += 1;
    }
  }

  logger.info(
    { checkpoint: "NO-GROUP-REM-02", ...result },
    "no-group reminder job completed"
  );
  return result;
}

async function collectActiveDevices(userId: string): Promise<RecipientDevice[]> {
  const snapshot = await getRealtimeDatabase().ref(`userDevices/${userId}`).get();
  if (!snapshot.exists() || !isRecord(snapshot.val())) return [];

  const devices: RecipientDevice[] = [];
  for (const [deviceId, value] of Object.entries(
    snapshot.val() as Record<string, unknown>
  )) {
    if (!isRecord(value)) continue;
    if ((value.deviceState ?? "active") !== "active") continue;
    const fcmToken = value.fcmToken?.toString().trim();
    if (!fcmToken) continue;
    devices.push({ userId, deviceId, fcmToken });
  }
  return devices;
}

async function sendReminderToDevices(
  devices: RecipientDevice[],
  state: NoGroupReminderState,
  nowSeconds: number
): Promise<boolean> {
  const pushResult = await sendPushToTokens({
    tokens: devices.map((device) => device.fcmToken),
    title: noGroupReminderCopy.title,
    body: noGroupReminderCopy.body,
    data: {
      type: "no_group_reminder"
    }
  });

  const updates: Record<string, unknown> = {};
  let anySuccess = false;

  devices.forEach((device, index) => {
    const response = pushResult.responses[index];
    if (response?.success) {
      anySuccess = true;
      return;
    }
    if (isPermanentMessagingTargetError(response?.error)) {
      updates[`userDevices/${device.userId}/${device.deviceId}/fcmToken`] = null;
      updates[
        `userDevices/${device.userId}/${device.deviceId}/registrationInvalidatedAt`
      ] = nowSeconds;
    }
  });

  if (anySuccess) {
    const next = nextReminderState(state, nowSeconds);
    const userId = devices[0]!.userId;
    updates[`userEngagement/${userId}/noGroupReminder`] = next;
  }

  if (Object.keys(updates).length > 0) {
    await getRealtimeDatabase().ref().update(updates);
  }

  return anySuccess;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
