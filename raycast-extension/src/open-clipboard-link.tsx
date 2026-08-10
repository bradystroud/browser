import {
  Action,
  ActionPanel,
  Clipboard,
  Icon,
  List,
  Toast,
  closeMainWindow,
  getSelectedText,
  popToRoot,
  showToast,
} from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { normalizeURL, openLink } from "./browser-cli";
import {
  profileAccessories,
  profileIcon,
  reportError,
  useProfiles,
} from "./shared";

/**
 * Selected text wins over the clipboard: if you've highlighted a link in
 * Slack/Mail and hit this command, that's the link you meant, even though
 * something older is still on the clipboard. `getSelectedText` throws
 * whenever the frontmost app exposes no selection (a common, expected case,
 * not an error worth surfacing), so it's a plain fall-through.
 */
async function detectURL(): Promise<string | undefined> {
  try {
    const selected = await getSelectedText();
    const fromSelection = normalizeURL(selected);
    if (fromSelection) return fromSelection;
  } catch {
    // No selection available — fall through to the clipboard.
  }
  return normalizeURL((await Clipboard.readText()) ?? "");
}

export default function OpenClipboardLinkCommand() {
  const { data: url, isLoading: isDetecting } = usePromise(detectURL);
  const { data: profiles, isLoading: isLoadingProfiles } = useProfiles();

  async function open(profileName: string | undefined, newWindow: boolean) {
    if (!url) return;
    try {
      const message = await openLink(url, profileName, newWindow);
      await showToast({
        style: Toast.Style.Success,
        title: "Opened in Browser",
        message,
      });
      await closeMainWindow();
      await popToRoot();
    } catch (error) {
      await reportError(error);
    }
  }

  const isLoading = isDetecting || isLoadingProfiles;

  if (!isLoading && !url) {
    return (
      <List>
        <List.EmptyView
          icon={Icon.Clipboard}
          title="No link found"
          description="Select a URL in another app, or copy one to the clipboard, then run this command again."
        />
      </List>
    );
  }

  return (
    <List
      isLoading={isLoading}
      navigationTitle={url ?? "Finding a link…"}
      searchBarPlaceholder="Filter profiles…"
    >
      <List.Section title={url ?? ""}>
        <List.Item
          icon={Icon.Shuffle}
          title="Use routing rules"
          subtitle="Let the app's own rules pick the profile"
          actions={
            <ActionPanel>
              <Action
                title="Open in New Tab"
                icon={Icon.Plus}
                onAction={() => open(undefined, false)}
              />
              <Action
                title="Open in New Window"
                icon={Icon.Window}
                shortcut={{ modifiers: ["cmd"], key: "return" }}
                onAction={() => open(undefined, true)}
              />
            </ActionPanel>
          }
        />
        {(profiles ?? []).map((profile) => (
          <List.Item
            key={profile.id}
            icon={profileIcon(profile)}
            title={profile.name}
            accessories={profileAccessories(profile)}
            actions={
              <ActionPanel>
                <Action
                  title="Open in New Tab"
                  icon={Icon.Plus}
                  onAction={() => open(profile.name, false)}
                />
                <Action
                  title="Open in New Window"
                  icon={Icon.Window}
                  shortcut={{ modifiers: ["cmd"], key: "return" }}
                  onAction={() => open(profile.name, true)}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
