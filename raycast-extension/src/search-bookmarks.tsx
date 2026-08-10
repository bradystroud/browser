import { Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { useState } from "react";
import { listAllBookmarks } from "./browser-cli";
import { OpenURLActions, ProfileSourceDropdown } from "./open-actions";
import { reportError, useProfiles } from "./shared";

export default function SearchBookmarksCommand() {
  const { data: profiles } = useProfiles();
  const [sourceProfile, setSourceProfile] = useState("");

  /**
   * Unlike history, the whole bookmark tree is small enough to load once and
   * let Raycast's built-in list filtering search it -- the CLI has no
   * bookmark-search command to push the query down to anyway (see
   * listAllBookmarks).
   */
  const { data: bookmarks, isLoading } = usePromise(
    (profile: string) => listAllBookmarks(profile || undefined),
    [sourceProfile],
    { onError: reportError },
  );

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search bookmarks…"
      searchBarAccessory={
        <ProfileSourceDropdown
          profiles={profiles ?? []}
          onChange={setSourceProfile}
        />
      }
    >
      <List.EmptyView
        icon={Icon.Bookmark}
        title="No bookmarks"
        description="This profile has no bookmarks, or none match your search."
      />
      {(bookmarks ?? []).map((bookmark) => (
        <List.Item
          key={`${bookmark.folder}-${bookmark.url}`}
          icon={Icon.Bookmark}
          title={bookmark.title || bookmark.url}
          subtitle={bookmark.url}
          accessories={
            bookmark.folder === "/" ? [] : [{ text: bookmark.folder }]
          }
          keywords={[bookmark.folder]}
          actions={
            <OpenURLActions url={bookmark.url} profiles={profiles ?? []} />
          }
        />
      ))}
    </List>
  );
}
