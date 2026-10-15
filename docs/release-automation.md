# Release automation

Every push to `main` that changes the app becomes a release.
`.github/workflows/release.yml` runs on GitHub's `xcode-27` runner and:

1. Picks the next version: major.minor from `Sources/App/mac/Info.plist.in`,
   patch one higher than the newest `v<major>.<minor>.*` tag.
2. Runs `scripts/release.sh --format dmg --version <version>`: build, sign,
   notarize, staple, and (when the Sparkle key is set) the appcast entry.
3. Creates the GitHub release `v<version>` with `Browser-<version>.dmg` and a
   stable-named copy, `Browser.dmg`. The website and README link to
   `releases/latest/download/Browser.dmg`, so they never go stale.
4. Pushes `docs/appcast.xml`, after the release exists.
5. Updates the cask in
   [bradystroud/homebrew-tap](https://github.com/bradystroud/homebrew-tap).

Pushes that change only docs, Markdown, `.beads/`, agent config, assets or the
Raycast extension do not release. Run the workflow by hand from the Actions
tab to release without a push.

To start a new minor line, change `CFBundleShortVersionString` in
`Info.plist.in` (for example to `0.2.0`). The next release is `0.2.0`.

## Secrets

Set these once with `gh secret set <NAME> -R bradystroud/browser`. The
workflow fails with a list of what is missing.

| Secret | What it is | How to get it |
| --- | --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key | Keychain Access → My Certificates → right-click "Developer ID Application: BRADY MATTHEW STROUD" → Export as `.p12`. Then `base64 -i cert.p12 \| gh secret set DEVELOPER_ID_P12_BASE64` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you gave that export | `gh secret set DEVELOPER_ID_P12_PASSWORD` |
| `PROVISIONING_PROFILE_BASE64` | The passkey provisioning profile | `base64 -i ~/.config/browser/Browser.provisionprofile \| gh secret set PROVISIONING_PROFILE_BASE64` |
| `NOTARY_API_KEY_BASE64` | An App Store Connect API key (`.p8`) for `notarytool` | App Store Connect → Users and Access → Integrations → Team Keys → add a key with the Developer role. Then `base64 -i AuthKey_XXXX.p8 \| gh secret set NOTARY_API_KEY_BASE64` |
| `NOTARY_API_KEY_ID` | That key's ID | Shown next to the key |
| `NOTARY_API_ISSUER` | The issuer ID | Shown above the key list |
| `SPARKLE_ED_PRIVATE_KEY` | Optional. Turns on the appcast entry | See `docs/auto-update.md` |
| `HOMEBREW_TAP_TOKEN` | Optional. Lets the workflow update the cask | A fine-grained personal access token with Contents: read and write on `bradystroud/homebrew-tap` only |

Delete the exported `.p12` and `.p8` files after you store them.

## When a release fails

The workflow stops at the first failed step, and nothing after it is
published. If it fails after the GitHub release exists, delete that release
and its tag, then re-run the workflow:

```
gh release delete v<version> --cleanup-tag -R bradystroud/browser
```
