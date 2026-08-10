import { Color, Icon, List, Toast, showToast } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { BrowserCLIError, Profile, getProfiles } from "./browser-cli";

/**
 * Every failure this extension can produce is either a `BrowserCLIError`
 * (already worded for a human, often with a hint about what to fix) or an
 * unexpected throw. Both end up as a failure toast rather than Raycast's
 * generic red error screen, because all of the likely causes -- Browser not
 * running, CLI not installed, a profile that no longer exists -- are things
 * the user fixes and retries, not crashes.
 */
export async function reportError(error: unknown): Promise<void> {
  if (error instanceof BrowserCLIError) {
    await showToast({
      style: Toast.Style.Failure,
      title: error.message,
      message: error.hint,
    });
    return;
  }
  await showToast({
    style: Toast.Style.Failure,
    title: "Something went wrong",
    message: error instanceof Error ? error.message : String(error),
  });
}

/**
 * Profiles always come from `browser profiles --json`, never a hardcoded
 * list -- adding a profile in the app must be enough to make it show up
 * here. Note this needs the app running (the live window count only exists
 * in the running process), which is why the error path matters as much as
 * the data path.
 */
export function useProfiles() {
  return usePromise(getProfiles, [], {
    onError: reportError,
  });
}

/** The profile's own colour, so the list reads like the app's own chrome. */
export function profileIcon(profile: Profile) {
  return { source: Icon.Circle, tintColor: profile.colorHex as Color };
}

export function profileAccessories(profile: Profile): List.Item.Accessory[] {
  if (profile.windowCount === 0) return [];
  return [
    {
      text: `${profile.windowCount} window${profile.windowCount === 1 ? "" : "s"}`,
    },
  ];
}
