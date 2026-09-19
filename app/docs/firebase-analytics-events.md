# Duo Firebase Analytics Events

Internal catalog for Firebase Console custom definitions and BigQuery export.

Product analytics go through `AnalyticsService`. Do not add raw `FirebaseAnalytics.logEvent` calls.

Engagement time, sessions, and unique users use Firebase automatic collection. Duo does **not** emit a custom `user_spent_time` event.

IDs in Analytics are `group_id_suffix` (last 8 characters) only. Full user/group IDs belong in operational device logs, not Analytics parameters.

## Button clicks

### button_click

Purpose:
Track important button interactions across screens. A single event (not `go_live_clicked`, `settings_clicked`, …) so Firebase can rank buttons by `button_name` and `screen_name`.

Parameters:
- `button_name` — `go_live`, `go_away`, `talk`, `nudge`, `settings`, `create_group`, `join_group`, `invite`, `continue_with_google`, `duo_pro`, `purchase`, `submit_create_group`, `submit_join_group`
- `screen_name` — `home`, `settings`, `paywall`, `google_auth`, `create_group`, `join_group`
- `feature` — optional

Triggered:
User taps an instrumented control. Auto-join from a nudge accept is **not** a `go_live` button click.

Expected values:
See `button_name` / `screen_name` lists above.

---

## Screens & journey

### screen_view

Purpose:
Named screen impressions (Firebase also collects automatic screen views when a named `Navigator` route exists).

Parameters:
- `screen_name`
- `screen_class` — optional widget class

Triggered:
Home, settings, paywall, Google auth, create/join group.

### feature_selected

Purpose:
Start of a user journey (home → feature → paywall → purchase).

Parameters:
- `feature` — `go_live`, `nudge`, `create_group`, `join_group`, `paywall`
- `screen_name`

Triggered:
User chooses that feature from home or settings.

### paywall_viewed

Purpose:
Paywall impression.

Parameters:
- `source` — `settings`

Triggered:
`ElevenProPaywallScreen` opens.

### trial_started

Purpose:
RevenueCat entitlement is in a trial or intro period after purchase.

Parameters:
- `package_id`

Triggered:
Successful purchase when `PeriodType` is `trial` or `intro`.

### purchase_started

Purpose:
Store purchase sheet requested.

Parameters:
- `package_id`

Triggered:
User confirms a Duo Pro package.

### purchase_completed

Purpose:
Pro entitlement is active after purchase or restore.

Parameters:
- `package_id`
- `method` — `purchase` or `restore`

Triggered:
RevenueCat reports the Pro entitlement after buy/restore.

### setup_completed

Purpose:
Onboarding finished (name + photo).

Parameters:
none

Triggered:
`IdentityRepository.markSetupComplete()` from onboarding. Legacy backfill does not emit this.

---

## Auth / identity (existing)

| Event | Purpose | Parameters | Triggered |
| --- | --- | --- | --- |
| `login` | Returning Google sign-in | `method=google` | Identity repository |
| `sign_up` | First Google sign-in | `method=google` | Identity repository |
| `logout` | User signed out | none | Identity repository |
| `account_deleted` | Account deleted | none | Identity repository |
| `profile_updated` | Profile field saved | `field` | Identity repository |
| `app_open` | Analytics init | none | `AnalyticsService.initialize` |
| `session_started` | App returned to foreground | none | `OneOneApp` lifecycle |
| `service_status_blocked` | Remote kill-switch | `status` | Service status gate |
| `app_error` | Non-analytics error breadcrumb | `error_type`, `is_fatal`, `feature`, `screen_name`, `reason` | Crashlytics wrapper |

---

## Groups

### group_created

Purpose:
New group created.

Parameters:
- `group_id_suffix`
- `member_count` — `1` at creation (no extra reads)

Triggered:
`GroupRepository.createGroup`

### group_joined

Purpose:
User joined via invite.

Parameters:
- `group_id_suffix`
- `source` — `invite`
- `member_count` — omitted unless already known

Triggered:
`GroupRepository.joinInvite`

### group_left

Purpose:
User left a group.

Parameters:
- `group_id_suffix`
- `member_count` — omitted (no extra read)

Triggered:
`GroupRepository.leaveGroup`

### invite_created

Purpose:
Invite link/PIN created.

Parameters:
- `group_id_suffix`

Triggered:
`GroupRepository.createInvite`

---

## Nudges

### nudge_sent

Purpose:
Backend accepted a nudge send.

Parameters:
- `group_id_suffix`
- `kind` / `nudge_type` — `push`, `ring`, `voice`
- `target_scope`
- `delivery_method` — `fcm`
- `audio_bytes`, `duration_ms` — voice/ring when known

Triggered:
`NudgeRepository.sendPush` / `sendRing` / `sendVoice` after accepted delivery.

### nudge_received

Purpose:
This device received an incoming nudge while Flutter was alive.

Parameters:
- `group_id_suffix`
- `nudge_type` — when the FCM payload includes `type`/`kind`
- `delivery_method` — `fcm`

Triggered:
`AndroidVoiceNudgeBridge._onIncomingNudge`

### nudge_failed

Purpose:
Product-level send or delivery failure (not a crash).

Parameters:
- `group_id_suffix`
- `nudge_type`
- `failure_reason` — `delivered` is never sent; failures use `device_unreachable`, `network_unavailable`, `timed_out`, `unknown`
- `delivery_method` — `fcm`

Triggered:
Send rejected (no recipients/devices/FCM), network send error, receiver-reported playback failure, or missing ACK after the confirmation window.

### nudge_responded

Purpose:
Recipient accept / decline / snooze.

Parameters:
- `group_id_suffix`
- `action`
- `snooze_minutes`

Triggered:
`NudgeRepository.respond`

---

## Talk / presence (existing)

| Event | Purpose | Parameters | Triggered |
| --- | --- | --- | --- |
| `go_online` | LiveKit presence live | `group_id_suffix`, `connection_mode`, `joined_call_mode` | Successful go-online |
| `go_away` | Left the room | `group_id_suffix`, `reason` | `_goAway` |
| `talk_start` | Call-mode mic on | `group_id_suffix` | Connection mode → call |
| `talk_stop` | Mic off / talk released | `group_id_suffix`, `reason` | Mode change or stop talk |
| `connection_mode_changed` | Walkie ↔ call | `group_id_suffix`, `mode` | Toggle |
| `daily_usage_cap_reached` | Daily cap | `group_id_suffix` | Presence cap |

`talk_start` / `talk_stop` are the talk events (not `talk_started` / `talk_stopped`).

---

## LiveKit

### livekit_session_started

Purpose:
High-level LiveKit session count.

Parameters:
- `group_id_suffix`

Triggered:
`Room.connect` succeeds on home.

### livekit_session_ended

Purpose:
Session duration and occupancy. Feature-level duration only — not a replacement for Firebase engagement time.

Parameters:
- `group_id_suffix`
- `duration` — seconds
- `participant_count` — local + remote at end

Triggered:
Once per started session on go-away, connection loss, or process teardown.

---

## Notifications

### notification_received

Purpose:
FCM nudge payload delivered to a live Flutter engine.

Parameters:
- `source` — `fcm`
- `nudge_type` — when present

Triggered:
Same path as `nudge_received`. Cold-start FCM handled only in native is not duplicated here.

### notification_opened

Purpose:
User opened a nudge notification (accept / connect / open).

Parameters:
- `nudge_type` — when present
- `action` — `accept`, `connect`, `open`

Triggered:
`AndroidVoiceNudgeBridge.takePendingNudgeAction`

---

## Operational logs (not Analytics)

Structured lines in on-device daily logs, uploaded as ZIP via `DeviceLogReport` → backend signed URL → Firebase Storage.

Format:

```text
event=nudge_failed event_type=nudge status=device_unreachable error=timeout sender=… receiver=… nudge_id=… group_id=…
```

`LogManager` already appends `{ userId, groupId, networkType, … }`.

| event | event_type | when |
| --- | --- | --- |
| `nudge_failed` | `nudge` | Send/delivery failure |
| `message_send_failed` | `chat` | RTDB chat write failed |
| `message_delivery_failed` | `chat` | Chat push notify failed |
| `connection_attempt` | `livekit` | `Room.connect` starts |
| `connection_success` | `livekit` | Connect succeeded |
| `connection_failed` | `livekit` | Connect threw |
| `disconnect` | `livekit` | Room disconnect |
| `session_start` | `livekit` | Session analytics start |
| `session_end` | `livekit` | Session analytics end |

Reachability values the app can actually prove:

- `delivered`
- `device_unreachable` — missing ACK; powered-off vs no-network cannot be distinguished
- `network_unavailable`
- `timed_out` — receiver reported timeout, or sender timeout
- `unknown`

Normal nudge failures are **not** Crashlytics fatals. Unexpected FCM handling bugs and LiveKit connect exceptions may still be recorded as non-fatal Crashlytics issues.

---

## Firebase Console (manual)

After shipping, register custom dimensions/metrics for:

- `button_name` (text)
- `screen_name` (text)
- `feature` (text)
- `nudge_type` (text)
- `failure_reason` (text)
- `delivery_method` (text)
- `group_id_suffix` (text)
- `member_count` (number)
- `duration` (number)
- `participant_count` (number)
- `package_id` (text)
- `method` (text)
- `source` (text)
- `action` (text)

Optional: audiences (nudge senders, Pro purchasers), BigQuery export, Google Analytics data stream debug.

Do not duplicate Firebase automatic session/engagement metrics as custom events.
