import {
  Action,
  ActionPanel,
  Form,
  Toast,
  closeMainWindow,
  popToRoot,
  showToast,
} from "@raycast/api";
import { useState } from "react";
import { normalizeURL, openLink } from "./browser-cli";
import { reportError, useProfiles } from "./shared";

interface FormValues {
  url: string;
  profile: string;
  newWindow: boolean;
}

/**
 * The "route it like a real link" option: an empty profile selection sends no
 * `--profile` at all, so the CLI puts the URL through the same
 * RuleMatcher/RoutingCoordinator path a clicked link from another app takes.
 * Any other value is an explicit override that bypasses routing rules.
 */
const ROUTE_BY_RULES = "";

export default function OpenLinkCommand() {
  const { data: profiles, isLoading } = useProfiles();
  const [urlError, setUrlError] = useState<string | undefined>();

  async function submit(values: FormValues) {
    const url = normalizeURL(values.url);
    if (!url) {
      setUrlError("Doesn’t look like a URL");
      return;
    }

    try {
      const message = await openLink(
        url,
        values.profile || undefined,
        values.newWindow,
      );
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
    <Form
      isLoading={isLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Open in Browser" onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="url"
        title="URL"
        placeholder="https://example.com"
        autoFocus
        error={urlError}
        onChange={() => setUrlError(undefined)}
      />
      <Form.Dropdown id="profile" title="Profile" storeValue>
        <Form.Dropdown.Item value={ROUTE_BY_RULES} title="Use routing rules" />
        {(profiles ?? []).map((profile) => (
          <Form.Dropdown.Item
            key={profile.id}
            value={profile.name}
            title={profile.name}
          />
        ))}
      </Form.Dropdown>
      <Form.Checkbox id="newWindow" label="Open in a new window" storeValue />
    </Form>
  );
}
