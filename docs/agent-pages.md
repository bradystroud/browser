# Agent pages

Enable Settings > Privacy > Agents before using `browser page` commands. Run
`browser page help` for the full command list.

`browser page open --profile <name>` reuses an existing profile or creates it
when missing, just like `browser open --profile <name>`. It opens one agent
window and returns its page ID. No separate profile setup window is needed.
The successful response message includes `(created)` when the profile is new, including
in `--json` output.

```sh
browser page open https://example.com --profile owner/repo --json
# Use the page.id from the response in subsequent commands.
browser page close <id>
```

Closing the last page in an agent window closes the window. If the page opened
popup tabs, close those pages too. The profile remains available, with its
sign-ins, for the next agent working on the same project. A new profile is saved
before its window opens, so it also remains if a later step, such as resizing
or waiting for the page, fails.

Profile names match exactly, so check the name before opening: a typo creates
another profile. Blank or whitespace-only names are refused.

Without `--profile`, the page uses the configured fallback profile. Use
`--private` for a temporary profile that is never saved. Opening a page with
`--opener <id>` uses the opener's profile and ignores `--profile` and `--private`.

