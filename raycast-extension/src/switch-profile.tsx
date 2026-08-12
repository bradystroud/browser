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
import { focusProfile, openNewWindow } from "./browser-cli";
import {
  profileAccessories,
  profileIcon,
  reportError,
  useProfiles,
} from "./shared";

/// "Take me to that profile" (browser-dpf): pick a profile and land in it,
/// whether or not it already has a window open. Distinct from the New Window
/// command next to it, which always creates one -- here a profile you already
/// have open is *focused*, so this can be used repeatedly to hop between
/// profiles without accumulating windows.
///
/// The reuse-or-create decision belongs to the app, not to this command: it
/// is one `browser focus` call, not a windows-listing followed by a choice
/// made here, which would be both an extra round trip and racy.
export default function SwitchProfileCommand() {
  const { data: profiles, isLoading, revalidate } = useProfiles();

  async function switchTo(profileName: string) {
    try {
      const message = await focusProfile(profileName);
      await showToast({
        style: Toast.Style.Success,
        title: profileName,
        message,
      });
      await closeMainWindow();
      await popToRoot();
    } catch (error) {
      await reportError(error);
    }
  }

  async function openNew(profileName: string) {
    try {
      const message = await openNewWindow(profileName);
      await showToast({
        style: Toast.Style.Success,
        title: "New window",
        message,
      });
      await closeMainWindow();
      await popToRoot();
    } catch (error) {
      await reportError(error);
    }
  }

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Filter profiles…">
      <List.EmptyView
        icon={Icon.AppWindow}
        title="No profiles"
        description="Launch Browser.app — profiles are read live from the running app."
      />
      {(profiles ?? []).map((profile) => (
        <List.Item
          key={profile.id}
          icon={profileIcon(profile)}
          title={profile.name}
          // The window count already tells you which branch this will take:
          // a profile showing no count has nothing open, so switching to it
          // will open a window rather than focus one.
          accessories={profileAccessories(profile)}
          actions={
            <ActionPanel>
              <Action
                title="Switch to Profile"
                icon={Icon.AppWindow}
                onAction={() => switchTo(profile.name)}
              />
              <Action
                title="Open New Window"
                icon={Icon.Window}
                shortcut={{ modifiers: ["cmd"], key: "n" }}
                onAction={() => openNew(profile.name)}
              />
              <Action
                title="Refresh Profiles"
                icon={Icon.ArrowClockwise}
                shortcut={Keyboard.Shortcut.Common.Refresh}
                onAction={revalidate}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
