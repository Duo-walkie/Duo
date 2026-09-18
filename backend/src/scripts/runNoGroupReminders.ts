/**
 * Manual / cron entrypoint for no-group engagement reminders.
 *
 * Usage:
 *   npm run no-group-reminders
 */
import { requireFirebaseAdminApp } from "../firebase/adminApp.js";
import { logger } from "../logger.js";
import { runNoGroupReminders } from "../notifications/noGroupReminderService.js";

async function main() {
  requireFirebaseAdminApp();
  const result = await runNoGroupReminders();
  logger.info({ checkpoint: "NO-GROUP-REM-SCRIPT", ...result }, "done");
  console.log(JSON.stringify(result, null, 2));
}

main().catch((error) => {
  logger.error(
    {
      checkpoint: "NO-GROUP-REM-E1",
      error: error instanceof Error ? error.message : String(error)
    },
    "no-group reminder script failed"
  );
  process.exitCode = 1;
});
