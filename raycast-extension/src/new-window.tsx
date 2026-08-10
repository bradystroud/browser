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
import { openNewWindow } from "./browser-cli";
import {
  profileAccessories,
  profileIcon,
  reportError,
  useProfiles,
} from "./shared";

export default function NewWindowCommand() {
  const { data: profiles, isLoading, revalidate } = useProfiles();

  async function open(profileName: string) {
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
        icon={Icon.Window}
        title="No profiles"
        description="Launch Browser.app — profiles are read live from the running app."
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
                title="Open New Window"
                icon={Icon.Window}
                onAction={() => open(profile.name)}
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
