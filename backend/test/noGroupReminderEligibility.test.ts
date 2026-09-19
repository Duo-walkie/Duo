import assert from "node:assert/strict";
import test from "node:test";
import {
  hasAnyGroups,
  isDueForReminder,
  isIdleNewUserCandidate,
  nextReminderState,
  noGroupReminderInactiveAfterSeconds,
  noGroupReminderIntervalSeconds,
  noGroupReminderMaxCount,
  noGroupReminderNewUserWindowSeconds,
  parseReminderState
} from "../src/notifications/noGroupReminderEligibility.js";

const day = 24 * 60 * 60;
const now = 1_700_000_000;

test("idle new user within 14d window and inactive 1d+ is eligible", () => {
  assert.equal(
    isIdleNewUserCandidate(
      {
        accountState: "active",
        createdAt: now - 3 * day,
        lastSeenAt: now - noGroupReminderInactiveAfterSeconds
      },
      now
    ),
    true
  );
});

test("recently active users are not candidates", () => {
  assert.equal(
    isIdleNewUserCandidate(
      {
        accountState: "active",
        createdAt: now - day,
        lastSeenAt: now - 60
      },
      now
    ),
    false
  );
});

test("users older than the new-user window are skipped", () => {
  assert.equal(
    isIdleNewUserCandidate(
      {
        accountState: "active",
        createdAt: now - noGroupReminderNewUserWindowSeconds - 1,
        lastSeenAt: now - 2 * day
      },
      now
    ),
    false
  );
});

test("disabled accounts are skipped", () => {
  assert.equal(
    isIdleNewUserCandidate(
      {
        accountState: "disabled",
        createdAt: now - day,
        lastSeenAt: now - 2 * day
      },
      now
    ),
    false
  );
});

test("hasAnyGroups detects membership index entries", () => {
  assert.equal(hasAnyGroups(null), false);
  assert.equal(hasAnyGroups({}), false);
  assert.equal(hasAnyGroups({ g1: { role: "owner" } }), true);
});

test("reminder cadence caps at three daily sends", () => {
  assert.equal(isDueForReminder({ count: 0, lastSentAt: 0 }, now), true);
  assert.equal(
    isDueForReminder(
      { count: 1, lastSentAt: now - noGroupReminderIntervalSeconds },
      now
    ),
    true
  );
  assert.equal(
    isDueForReminder(
      { count: 1, lastSentAt: now - noGroupReminderIntervalSeconds + 1 },
      now
    ),
    false
  );
  assert.equal(
    isDueForReminder({ count: noGroupReminderMaxCount, lastSentAt: 0 }, now),
    false
  );
});

test("parse and next reminder state", () => {
  assert.deepEqual(parseReminderState(null), { count: 0, lastSentAt: 0 });
  assert.deepEqual(parseReminderState({ count: 2, lastSentAt: 99 }), {
    count: 2,
    lastSentAt: 99
  });
  assert.deepEqual(nextReminderState({ count: 1, lastSentAt: 10 }, now), {
    count: 2,
    lastSentAt: now
  });
});
