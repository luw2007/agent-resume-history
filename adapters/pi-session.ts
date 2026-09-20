/**
 * Agent Resume History (AHR) adapter for OMP and Pi.
 *
 * Contract:
 * - Accepts process.env.AHR_RUN_FILE.
 * - Records only `session_start` from an interactive parent (`mode === "tui"` or `hasUI === true`).
 * - Reads the actual session ID from ctx.sessionManager.getSessionId().
 * - Requires a resumable session path, but not an already-persisted file.
 * - Invokes $AHR_HOME/bin/agent-resume-history-record (or default ~/.local/share/agent-resume-history/bin/agent-resume-history-record).
 * - Does not scan session directories.
 */

import * as path from "node:path";
import { spawnSync } from "node:child_process";

interface SessionManager {
  getSessionId?: () => unknown;
  getSessionFile?: () => unknown;
}

interface ExtensionContext {
  sessionManager?: SessionManager;
  mode?: string;
  hasUI?: boolean;
  cwd?: string;
}

interface ExtensionAPI {
  on: (event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => void;
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function resolveRecorderPath(): string {
  const ahrHome = process.env.AHR_HOME;
  if (ahrHome && ahrHome.trim().length > 0) {
    return path.join(ahrHome, "bin", "agent-resume-history-record");
  }
  const home = process.env.HOME || "";
  return path.join(home, ".local", "share", "agent-resume-history", "bin", "agent-resume-history-record");
}

function recordSession(ctx: ExtensionContext | undefined): void {
  const markerPath = process.env.AHR_RUN_FILE;
  if (!markerPath || typeof markerPath !== "string") {
    return;
  }

  const sessionManager = ctx?.sessionManager;
  if (!sessionManager) {
    return;
  }

  // A fresh OMP session has a path before its file is first persisted.
  let sessionFile: unknown;
  try {
    sessionFile = typeof sessionManager.getSessionFile === "function" ? sessionManager.getSessionFile() : undefined;
  } catch {
    return;
  }

  if (typeof sessionFile !== "string" || !sessionFile) {
    return;
  }
  let rawId: unknown;
  try {
    rawId = typeof sessionManager.getSessionId === "function" ? sessionManager.getSessionId() : undefined;
  } catch {
    return;
  }

  if (typeof rawId !== "string" || !rawId) {
    return;
  }

  const trimmedId = rawId.trim();
  if (!UUID_REGEX.test(trimmedId)) {
    return;
  }

  // 3. Invoke central recorder
  const recorderBinary = resolveRecorderPath();
  try {
    spawnSync(recorderBinary, [markerPath, trimmedId], {
      stdio: "ignore",
      timeout: 5000,
    });
  } catch {
    // Non-blocking: recording failure must never crash or block agent session
  }
}

export default function ahrSessionExtension(pi: ExtensionAPI): void {
  // Pi identifies its interactive parent with mode=tui. OMP does not expose
  // mode; its top-level TUI has hasUI=true, while in-process children do not.
  try {
    pi.on("session_start", (_event: unknown, ctx: ExtensionContext) => {
      if (ctx.mode === "tui" || ctx.hasUI === true) {
        recordSession(ctx);
      }
    });
  } catch {
    // Ignore runtimes that do not expose this lifecycle event.
  }
}
