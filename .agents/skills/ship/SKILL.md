---
name: ship
description: Build the browser and update the local /Applications/Browser.app installation. Use when Brady says "ship", "ship it", "update my install", or wants the installed app refreshed with the latest code.
---

# Ship: build → install → relaunch

Update Brady's local installation at /Applications/Browser.app from the current working tree.

1. **Build.** `./scripts/build.sh` from the repo root. On failure: stop, show the last ~20 lines of build output, do not touch the installed app.
2. **Install.** `./scripts/install.sh` — this quits any running Browser instance first (required: two instances must never share `root_cache_path`), copies the built app to /Applications with `ditto`, and re-registers it with Launch Services (keeps default-browser eligibility).
3. **Relaunch.** `open /Applications/Browser.app`, then confirm the process is up (`pgrep -f Applications/Browser.app`). Profiles/settings/history are safe — all state lives in `~/Library/Application Support/Browser/`, which install never touches.
4. **Say what shipped.** Print `git log --oneline -8` and one line per user-visible change since the last ship. If any just-shipped change has an unverified Test/Expect/Report hand-off (check recent docs/ai-tasks/ notes), surface that checklist now — shipping is when Brady can actually run it.

Ship from the current tree even if it has uncommitted work — that's usually the point (testing in-flight changes). Mention in the report if the shipped build includes uncommitted files.
