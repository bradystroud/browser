import {
  Action,
  ActionPanel,
  Icon,
  List,
  Toast,
  closeMainWindow,
  popToRoot,
  showToast,
  Keyboard,
} from "@raycast/api";
import { Profile, openLink } from "./browser-cli";
import { profileIcon, reportError } from "./shared";

/**
 * The action set shared by the history and bookmark result lists: open the
 * result the way a clicked link would be routed, or force a specific
 * profile, as a tab or a window. Kept in one place so the two lists can't
 * drift into offering different shortcuts for the same idea.
 */
export function OpenURLActions({
  url,
  profiles,
}: {
  url: string;
  profiles: Profile[];
}) {
  async function open(profileName: string | undefined, newWindow: boolean) {
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

  return (
    <ActionPanel>
      <Action
        title="Open (Routing Rules)"
        icon={Icon.Globe}
        onAction={() => open(undefined, false)}
      />
      <ActionPanel.Submenu title="Open in Profile" icon={Icon.Person}>
        {profiles.map((profile) => (
          <Action
            key={profile.id}
            title={profile.name}
            icon={profileIcon(profile)}
            onAction={() => open(profile.name, false)}
          />
        ))}
      </ActionPanel.Submenu>
      <ActionPanel.Submenu
        title="Open in New Window in Profile"
        icon={Icon.Window}
        shortcut={{ modifiers: ["cmd"], key: "return" }}
      >
        {profiles.map((profile) => (
          <Action
            key={profile.id}
            title={profile.name}
            icon={profileIcon(profile)}
            onAction={() => open(profile.name, true)}
          />
        ))}
      </ActionPanel.Submenu>
      <Action.CopyToClipboard
        title="Copy URL"
        content={url}
        shortcut={Keyboard.Shortcut.Common.Copy}
      />
    </ActionPanel>
  );
}

/**
 * The "which profile's data am I looking at" dropdown both search commands
 * put in their search bar. An empty value means "no `--profile` flag", which
 * the CLI resolves to the default profile's own `browser.db` -- note that's
 * a per-profile database on disk, so unlike the open commands there's no
 * "all profiles" option to offer here.
 */
export function ProfileSourceDropdown({
  profiles,
  onChange,
}: {
  profiles: Profile[];
  onChange: (value: string) => void;
}) {
  return (
    <List.Dropdown tooltip="Profile to search" storeValue onChange={onChange}>
      <List.Dropdown.Item value="" title="Default profile" />
      {profiles.map((profile) => (
        <List.Dropdown.Item
          key={profile.id}
          value={profile.name}
          title={profile.name}
        />
      ))}
    </List.Dropdown>
  );
}
