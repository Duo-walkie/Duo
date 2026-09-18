import { Router } from "express";
import { config } from "../config.js";
import { asyncHandler } from "../http/asyncHandler.js";
import { HttpError } from "../http/httpError.js";
import { runNoGroupReminders } from "../notifications/noGroupReminderService.js";

function requireInternalJobSecret(
  request: { header(name: string): string | undefined },
  _response: unknown,
  next: (error?: unknown) => void
) {
  const configured = config.INTERNAL_JOB_SECRET?.trim();
  if (!configured) {
    next(
      new HttpError(
        503,
        "internal_jobs_unconfigured",
        "INTERNAL_JOB_SECRET is not configured."
      )
    );
    return;
  }

  const provided =
    request.header("x-internal-job-secret")?.trim() ||
    parseBearer(request.header("authorization"));

  if (!provided || provided !== configured) {
    next(new HttpError(401, "unauthorized", "Invalid internal job secret."));
    return;
  }

  next();
}

function parseBearer(headerValue: string | undefined) {
  if (!headerValue) return null;
  const [scheme, token] = headerValue.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !token) return null;
  return token.trim();
}

export function createInternalJobRoutes() {
  const router = Router();

  router.post(
    "/v1/internal/jobs/no-group-reminders",
    requireInternalJobSecret,
    asyncHandler(async (_request, response) => {
      const result = await runNoGroupReminders();
      response.status(200).json({ ok: true, ...result });
    })
  );

  return router;
}
