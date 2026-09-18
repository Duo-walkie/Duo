/** New users within this window after account creation are reminder-eligible. */
export const noGroupReminderNewUserWindowSeconds = 14 * 24 * 60 * 60;

/** Must not have opened the app for at least this long. */
export const noGroupReminderInactiveAfterSeconds = 24 * 60 * 60;

/** Minimum gap between successive reminders. */
export const noGroupReminderIntervalSeconds = 24 * 60 * 60;

/** Cap how many times we nudge a user about creating a group. */
export const noGroupReminderMaxCount = 3;

export const noGroupReminderCopy = {
  title: "Create a group",
  body: "Create a group and send invites to your friends"
} as const;

export type NoGroupReminderState = {
  count: number;
  lastSentAt: number;
};

export type NoGroupReminderUserSnapshot = {
  accountState?: string;
  createdAt?: number;
  lastSeenAt?: number;
};

/**
 * Whether this active account is a "new" user who has gone idle long enough
 * to deserve a create-group reminder (ignores group membership and prior sends).
 */
export function isIdleNewUserCandidate(
  user: NoGroupReminderUserSnapshot,
  nowSeconds: number
): boolean {
  if ((user.accountState ?? "active") !== "active") return false;

  const createdAt = readPositiveInt(user.createdAt);
  const lastSeenAt = readPositiveInt(user.lastSeenAt);
  if (createdAt === 0 || lastSeenAt === 0) return false;

  if (nowSeconds - createdAt > noGroupReminderNewUserWindowSeconds) return false;
  if (nowSeconds - lastSeenAt < noGroupReminderInactiveAfterSeconds) return false;
  return true;
}

export function hasAnyGroups(userGroupsValue: unknown): boolean {
  if (userGroupsValue == null) return false;
  if (typeof userGroupsValue !== "object") return false;
  return Object.keys(userGroupsValue as Record<string, unknown>).length > 0;
}

export function parseReminderState(value: unknown): NoGroupReminderState {
  if (!isRecord(value)) {
    return { count: 0, lastSentAt: 0 };
  }
  return {
    count: Math.max(0, readPositiveInt(value.count)),
    lastSentAt: Math.max(0, readPositiveInt(value.lastSentAt))
  };
}

/** True when we may send another reminder now, given prior send history. */
export function isDueForReminder(
  state: NoGroupReminderState,
  nowSeconds: number
): boolean {
  if (state.count >= noGroupReminderMaxCount) return false;
  if (state.lastSentAt <= 0) return true;
  return nowSeconds - state.lastSentAt >= noGroupReminderIntervalSeconds;
}

export function nextReminderState(
  state: NoGroupReminderState,
  nowSeconds: number
): NoGroupReminderState {
  return {
    count: state.count + 1,
    lastSentAt: nowSeconds
  };
}

function readPositiveInt(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.max(0, Math.trunc(value));
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return Math.max(0, Math.trunc(parsed));
  }
  return 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
