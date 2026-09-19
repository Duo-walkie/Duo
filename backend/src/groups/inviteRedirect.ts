export const ANDROID_PACKAGE_NAME = "app.oneone.one_one_app";

export function playStoreListingUrl(inviteCode: string): string {
  const referrer = encodeURIComponent(`inviteCode=${inviteCode}`);
  return `https://play.google.com/store/apps/details?id=${ANDROID_PACKAGE_NAME}&referrer=${referrer}`;
}

export function customSchemeInviteUrl(inviteCode: string): string {
  return `oneone://invite/${encodeURIComponent(inviteCode)}`;
}

/**
 * Chrome / Android WebView Intent URL. If Duo is installed it opens
 * `oneone://invite/<code>`. If it is not, Chrome follows
 * `browser_fallback_url` to the Play Store listing with the install referrer.
 */
export function androidIntentInviteUrl(inviteCode: string): string {
  const playStoreUrl = playStoreListingUrl(inviteCode);
  return (
    `intent://invite/${encodeURIComponent(inviteCode)}#Intent;` +
    `scheme=oneone;` +
    `package=${ANDROID_PACKAGE_NAME};` +
    `S.browser_fallback_url=${encodeURIComponent(playStoreUrl)};` +
    `end`
  );
}

export function androidInviteLandingHtml(inviteCode: string): string {
  const intentUrl = escapeHtml(androidIntentInviteUrl(inviteCode));
  const customUrl = escapeHtml(customSchemeInviteUrl(inviteCode));
  const storeUrl = escapeHtml(playStoreListingUrl(inviteCode));

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Cache-Control" content="no-store">
<title>Open Duo</title>
<style>
  html, body { margin: 0; min-height: 100%; background: #101010; color: #f4f4f4;
    font-family: system-ui, -apple-system, sans-serif; }
  body { display: flex; flex-direction: column; align-items: center; justify-content: center;
    gap: 16px; padding: 32px 20px; text-align: center; }
  h1 { font-size: 1.4rem; font-weight: 650; margin: 0; }
  p { margin: 0; color: #c8c8c8; max-width: 22rem; line-height: 1.45; }
  a { display: inline-block; padding: 12px 20px; border-radius: 999px; font-weight: 650;
    text-decoration: none; }
  .primary { background: #F8BE03; color: #101010; }
  .secondary { color: #F8BE03; }
</style>
</head>
<body>
  <h1>Opening Duo</h1>
  <p>If you already have the app, this takes you straight to the group. Otherwise you will be sent to the Play Store.</p>
  <a class="primary" id="open" href="${customUrl}" data-intent="${intentUrl}">Open in Duo</a>
  <a class="secondary" id="store" href="${storeUrl}">Get the app on Play Store</a>
  <script>
    (function () {
      var open = document.getElementById("open");
      if (!open) return;
      var intentUrl = open.getAttribute("data-intent");
      if (!intentUrl) return;
      // Chrome/Custom Tabs: opens Duo when installed, otherwise follows
      // browser_fallback_url to Play Store with the install referrer.
      // Do not time out to the store ourselves — that hijacks users who
      // already have the app if the browser stays visible after handoff.
      window.location.replace(intentUrl);
    })();
  </script>
</body>
</html>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
