import { Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { useState } from "react";
import { searchHistory } from "./browser-cli";
import { OpenURLActions, ProfileSourceDropdown } from "./open-actions";
import { reportError, useProfiles } from "./shared";

export default function SearchHistoryCommand() {
  const { data: profiles } = useProfiles();
  const [sourceProfile, setSourceProfile] = useState("");
  const [query, setQuery] = useState("");

  /**
   * Searched server-side by the CLI (a real SQL LIKE against that profile's
   * browser.db), not by Raycast's own list filtering -- history is far too
   * large to pull down and filter locally, and the CLI already takes a query
   * and a limit. Hence `throttle` plus `filtering={false}`.
   */
  const { data: entries, isLoading } = usePromise(
    async (searchQuery: string, profile: string) =>
      searchQuery ? searchHistory(searchQuery, profile || undefined) : [],
    [query, sourceProfile],
    { onError: reportError },
  );

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      throttle
      onSearchTextChange={setQuery}
      searchBarPlaceholder="Search history…"
      searchBarAccessory={
        <ProfileSourceDropdown
          profiles={profiles ?? []}
          onChange={setSourceProfile}
        />
      }
    >
      <List.EmptyView
        icon={Icon.MagnifyingGlass}
        title={query ? "No matches" : "Search your history"}
        description={
          query
            ? "Nothing in this profile's history matches."
            : "Type to search this profile's history."
        }
      />
      {(entries ?? []).map((entry) => (
        <List.Item
          key={`${entry.url}-${entry.lastVisitTime}`}
          icon={Icon.Clock}
          title={entry.title || entry.url}
          subtitle={entry.url}
          accessories={[{ text: `${entry.visitCount}×` }]}
          actions={<OpenURLActions url={entry.url} profiles={profiles ?? []} />}
        />
      ))}
    </List>
  );
}
