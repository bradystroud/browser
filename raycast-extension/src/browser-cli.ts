import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { getPreferenceValues } from "@raycast/api";

const execFileAsync = promisify(execFile);

/**
 * Where the `browser` CLI lives when it hasn't been symlinked onto PATH.
 * Raycast commands do not inherit a login shell's PATH, so resolving the
 * binary by name is not an option here even when `browser` works fine in a
 * terminal -- these are always absolute paths.
 */
const DEFAULT_CLI_PATHS = [
  "/usr/local/bin/browser",
  "/Applications/Browser.app/Contents/Resources/bin/browser",
];

export interface Preferences {
  cliPath?: string;
  profilesRoot?: string;
}

export interface Profile {
  id: string;
  name: string;
  colorHex: string;
  windowCount: number;
}

export interface HistoryEntry {
  url: string;
  title: string;
  visitCount: number;
  lastVisitTime: string;
}

export interface BookmarkItem {
  id: number;
  kind: "folder" | "bookmark";
  title: string;
  url: string | null;
}

/**
 * A failure that already carries a message worth showing the user verbatim
 * in a toast -- either the CLI's own `{"ok":false,"error":"..."}` payload or
 * one of the two setup problems this extension can detect itself (no binary
 * found, no running instance).
 */
export class BrowserCLIError extends Error {
  readonly hint?: string;

  constructor(message: string, hint?: string) {
    super(message);
    this.name = "BrowserCLIError";
    this.hint = hint;
  }
}

export function resolveCLIPath(): string {
  const configured = getPreferenceValues<Preferences>().cliPath?.trim();
  if (configured) {
    if (!existsSync(configured)) {
      throw new BrowserCLIError(
        "Browser CLI not found",
        `Nothing at ${configured}. Fix the “Browser CLI Path” preference for this extension.`,
      );
    }
    return configured;
  }

  const found = DEFAULT_CLI_PATHS.find((path) => existsSync(path));
  if (!found) {
    throw new BrowserCLIError(
      "Browser CLI not found",
      "Looked in /usr/local/bin/browser and /Applications/Browser.app/Contents/Resources/bin/browser. Build and install Browser.app, or set the extension's “Browser CLI Path” preference.",
    );
  }
  return found;
}

/**
 * `--profiles-root` must be two separate argv entries; the CLI rejects any
 * single token that merely starts with the flag rather than silently falling
 * back to the real instance (see BrowserCLIEntry.malformedProfilesRootArgument),
 * so passing an array element with an embedded space here would be a hard
 * error, not a quiet mis-target.
 */
function profilesRootArgs(): string[] {
  const root = getPreferenceValues<Preferences>().profilesRoot?.trim();
  return root ? ["--profiles-root", root] : [];
}

/**
 * Runs the CLI with `--json` and returns the parsed payload.
 *
 * Every command prints exactly one line of JSON to stdout on both success
 * and failure (see the CLI's own `Output` enum), and exits 1 on failure --
 * so a rejected `execFile` still has a JSON body worth reading, and the
 * error path below deliberately parses stdout before falling back to
 * anything else.
 */
async function runCLI<T>(args: string[]): Promise<T> {
  const cli = resolveCLIPath();
  const argv = [...args, ...profilesRootArgs(), "--json"];

  let stdout: string;
  try {
    ({ stdout } = await execFileAsync(cli, argv, { timeout: 15_000 }));
  } catch (error) {
    const failure = error as {
      stdout?: string;
      stderr?: string;
      message?: string;
    };
    const reported = parseError(failure.stdout);
    if (reported) {
      throw toFriendlyError(reported);
    }
    throw new BrowserCLIError(
      "Browser CLI failed",
      failure.stderr?.trim() || failure.message || "Unknown error.",
    );
  }

  let parsed: T & { ok?: boolean; error?: string };
  try {
    parsed = JSON.parse(stdout);
  } catch {
    throw new BrowserCLIError(
      "Unreadable response from the Browser CLI",
      stdout.slice(0, 200),
    );
  }
  if (parsed.ok === false) {
    throw toFriendlyError(parsed.error ?? "Unknown error.");
  }
  return parsed;
}

function parseError(stdout: string | undefined): string | undefined {
  if (!stdout) return undefined;
  try {
    const parsed = JSON.parse(stdout) as { ok?: boolean; error?: string };
    return parsed.ok === false ? (parsed.error ?? "Unknown error.") : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The one CLI error worth rewording: "no socket at ..." is precise but
 * assumes you know what the socket is for. Everything else the CLI says is
 * already written for a human.
 */
function toFriendlyError(message: string): BrowserCLIError {
  if (message.includes("No running Browser instance")) {
    return new BrowserCLIError(
      "Browser isn’t running",
      "Launch Browser.app, then try again.",
    );
  }
  return new BrowserCLIError("Browser CLI error", message);
}

export async function getProfiles(): Promise<Profile[]> {
  const response = await runCLI<{ profiles?: Profile[] }>(["profiles"]);
  return response.profiles ?? [];
}

export async function openLink(
  url: string,
  profile: string | undefined,
  newWindow: boolean,
): Promise<string> {
  const args = ["open", url];
  if (profile) args.push("--profile", profile);
  if (newWindow) args.push("--new-window");
  const response = await runCLI<{ message?: string }>(args);
  return response.message ?? `Opened ${url}`;
}

export async function openNewWindow(
  profile: string | undefined,
  url?: string,
): Promise<string> {
  const args = ["window", "new"];
  if (url) args.push(url);
  if (profile) args.push("--profile", profile);
  const response = await runCLI<{ message?: string }>(args);
  return response.message ?? "Opened a new window";
}

export async function searchHistory(
  query: string,
  profile: string | undefined,
  limit = 50,
): Promise<HistoryEntry[]> {
  const args = ["history", "search", query, "--limit", String(limit)];
  if (profile) args.push("--profile", profile);
  const response = await runCLI<{ entries?: HistoryEntry[] }>(args);
  return response.entries ?? [];
}

export interface FlatBookmark {
  title: string;
  url: string;
  folder: string;
}

/**
 * The CLI has no bookmark *search* -- `bookmarks list` returns one folder's
 * direct children -- so this walks the tree breadth-first, one invocation per
 * folder, and lets Raycast's own list filtering do the searching. Bookmark
 * trees are small and each call is a plain SQLite read with no running app
 * required, but `maxFolders` still bounds a pathological tree rather than
 * spawning unboundedly.
 */
export async function listAllBookmarks(
  profile: string | undefined,
  maxFolders = 60,
): Promise<FlatBookmark[]> {
  const bookmarks: FlatBookmark[] = [];
  const queue: string[] = [""];
  let visited = 0;

  while (queue.length > 0 && visited < maxFolders) {
    const folder = queue.shift() as string;
    visited += 1;

    const args = ["bookmarks", "list"];
    if (folder) args.push("--folder", folder);
    if (profile) args.push("--profile", profile);
    const response = await runCLI<{ items?: BookmarkItem[] }>(args);

    for (const item of response.items ?? []) {
      if (item.kind === "folder") {
        queue.push(folder ? `${folder}/${item.title}` : item.title);
      } else if (item.url) {
        bookmarks.push({
          title: item.title,
          url: item.url,
          folder: folder || "/",
        });
      }
    }
  }

  return bookmarks;
}

/**
 * Turns whatever the user typed/copied into something worth handing to
 * `browser open`. Bare hostnames ("news.ycombinator.com") get an https://
 * prefix so they route by domain like a real link would; anything that
 * already has a scheme is passed through untouched, including non-http ones
 * the app may handle itself.
 */
export function normalizeURL(raw: string): string | undefined {
  const trimmed = raw.trim();
  if (!trimmed || /\s/.test(trimmed)) return undefined;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) return trimmed;
  if (/^[a-z0-9-]+(\.[a-z0-9-]+)+(\/.*)?$/i.test(trimmed))
    return `https://${trimmed}`;
  return undefined;
}
