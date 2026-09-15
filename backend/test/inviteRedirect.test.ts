import assert from "node:assert/strict";
import test from "node:test";
import {
  ANDROID_PACKAGE_NAME,
  androidIntentInviteUrl,
  androidInviteLandingHtml,
  customSchemeInviteUrl,
  playStoreListingUrl
} from "../src/groups/inviteRedirect.js";

const inviteCode = "AB12-XY9";

test("Play Store listing embeds the invite code as an install referrer", () => {
  const url = playStoreListingUrl(inviteCode);
  assert.ok(url.includes(`id=${ANDROID_PACKAGE_NAME}`));
  assert.ok(url.includes(`referrer=${encodeURIComponent(`inviteCode=${inviteCode}`)}`));
});

test("custom scheme and intent URLs target the same invite host and code", () => {
  assert.equal(customSchemeInviteUrl(inviteCode), `oneone://invite/${encodeURIComponent(inviteCode)}`);
  const intentUrl = androidIntentInviteUrl(inviteCode);
  assert.ok(intentUrl.startsWith(`intent://invite/${encodeURIComponent(inviteCode)}#Intent;`));
  assert.ok(intentUrl.includes("scheme=oneone;"));
  assert.ok(intentUrl.includes(`package=${ANDROID_PACKAGE_NAME};`));
  assert.ok(
    intentUrl.includes(
      `S.browser_fallback_url=${encodeURIComponent(playStoreListingUrl(inviteCode))};`
    )
  );
  assert.ok(intentUrl.endsWith("end"));
});

test("Android landing page tries the app first and keeps a Play Store fallback", () => {
  const html = androidInviteLandingHtml(inviteCode);
  assert.ok(html.includes("Open in Duo"));
  assert.ok(html.includes("Get the app on Play Store"));
  assert.ok(html.includes(`href="${customSchemeInviteUrl(inviteCode)}"`));
  assert.ok(html.includes(playStoreListingUrl(inviteCode).replaceAll("&", "&amp;")));
  assert.ok(html.includes("window.location.replace(intentUrl)"));
  assert.ok(!html.includes("<script src="));
});
