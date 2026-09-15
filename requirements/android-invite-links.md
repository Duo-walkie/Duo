# Android group invite links

## Implemented flow

1. `POST /v1/groups/:groupId/invites` returns the existing one-time PIN plus an
   HTTPS `inviteUrl`.
2. Android shares the HTTPS URL through the system share sheet.
3. A verified App Link opens `MainActivity` directly. If the browser still
   opens the HTTPS URL (unverified links, in-app browsers), Android gets a
   landing page that opens Duo when it is installed and otherwise sends the
   user to Play Store with the invite code as the Play Install Referrer.
4. Once an authenticated identity is ready, the app calls the existing join
   endpoint, clears the pending code only after success (or a terminal invite
   error), and opens Home focused on the joined group. Fresh installs recover
   the same code from the Play Install Referrer.
5. The PIN remains available as a fallback.

## One-time deployment setup

- Set `PUBLIC_INVITE_BASE_URL=https://one-one-xw00.onrender.com/invite` on the
  backend. If the public host changes, update the HTTPS host in
  `AndroidManifest.xml` and `InviteLinkContract.httpsHost` in the same release.
- In Play Console, copy the SHA-256 certificate fingerprint from **Setup > App
  integrity > App signing key certificate**.
- Set `ANDROID_APP_LINK_SHA256_CERT_FINGERPRINTS` on the backend. Use a
  comma-separated list when both Play signing and an internal/test signing
  certificate must open verified links.
- Deploy the backend and confirm
  `https://one-one-xw00.onrender.com/.well-known/assetlinks.json` returns the
  package `app.oneone.one_one_app` and every expected SHA-256 fingerprint as
  JSON, without authentication or a redirect.
- Deploy the backend before distributing an app build that shares these links.
  Without domain verification, the HTTPS landing page still opens the installed
  app via `oneone://invite/<code>` / the Android intent URL, and sends everyone
  else to Play Store with the install referrer.

## Device verification

- Create an invite and share it to the second Android device.
- With the app installed: tap the link and confirm the recipient joins without
  entering the PIN and lands with the invited group selected. They must not be
  sent to Play Store.
- Without the app: tap the link, install from Play Store, complete setup, and
  confirm they land in the invited group without entering the PIN.
- Repeat the installed-app path while logged in, logged out, and after removing
  the app from Recents.
- Test an expired and fully-used invite; the app must show the server error and
  must not repeatedly retry that terminal link.
