# White-labelling Zikk

Zikk is built so that a fork can ship under its own name, identifier, icon and signing identity by editing
**one configuration file**, regenerating the icon, and rebuilding. No Swift code changes are needed.

## 1. Edit `Config/Branding.xcconfig`

```xcconfig
APP_NAME = Acme API                 // Dock, menu bar, Finder, About panel, User-Agent, generated docs
APP_BUNDLE_ID = com.acme.acmeapi   // must be unique; register it in App Store Connect
APP_URL_SCHEME = acmeapi            // OAuth 2.0 redirect URI becomes acmeapi://oauth/callback
APP_COPYRIGHT = © 2026 Acme Inc.
MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 1
DEVELOPMENT_TEAM = ABCDE12345        // your Apple Developer Team ID
```

What each value drives:

| Setting | Used for |
|---|---|
| `APP_NAME` | `PRODUCT_NAME` (the `.app` name), `CFBundleDisplayName`/`CFBundleName`, and at runtime `Branding.appName` → default `User-Agent` (`<name>/<version>`) and the footer of exported HTML docs |
| `APP_BUNDLE_ID` | `PRODUCT_BUNDLE_IDENTIFIER`, the sandbox container (`~/Library/Containers/<id>`), the Keychain service for secrets (`<id>.secrets`), the UI test bundle (`<id>.uitests`) |
| `APP_URL_SCHEME` | Default OAuth 2.0 callback URL (`<scheme>://oauth/callback`) used by `ASWebAuthenticationSession` |
| `APP_COPYRIGHT` | `NSHumanReadableCopyright` (About panel) |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `CFBundleShortVersionString` / `CFBundleVersion`, and the version in the `User-Agent` |
| `DEVELOPMENT_TEAM` | Code signing for local runs, notarization and App Store uploads |

At runtime these values are read from the app's Info.plist by `Packages/ZikkKit/Sources/APICore/Branding.swift`
(`AppBrandName`, `AppURLScheme`, bundle id and version). Outside the app (unit tests, previews) the defaults in that file are used.

## 2. Regenerate the icon

```sh
swift scripts/make_icon.swift --top 22C55E --bottom 0E7490              # bolt on your gradient
swift scripts/make_icon.swift --text A --top F97316 --bottom DB2777     # a letter instead of the bolt
```

This writes every macOS size into `App/Assets.xcassets/AppIcon.appiconset`. To use artwork of your own, replace the PNGs
there (16–1024 px, see `Contents.json`) instead. Do not use SF Symbols in an app icon — Apple's license forbids it.

## 3. Build

```sh
xcodegen generate
xcodebuild -scheme Zikk -configuration Release -destination 'platform=macOS' build
```

The project, target and scheme keep the internal name `Zikk`; only the product changes. If you also want the Xcode
project/target named after your brand, rename `name:`, the `Zikk`/`ZikkUITests` targets and the scheme in `project.yml`
(and `-scheme` in the commands above). Internal Swift module names (`ZikkKit`, `Features`, …) never appear to users and can stay.

## 4. Optional: text and languages

- UI strings live in code as `L("…")` and are translated through `Localization/vi.json` + `scripts/sync_strings.py`
  (see `CLAUDE.md`). None of them contain the product name, so no text edits are required.
- To add a language: add its code to `CFBundleLocalizations` in `project.yml`, extend `scripts/sync_strings.py` to emit that
  language from a new `Localization/<code>.json`, and run the script.

## 5. Distribution checklist

- [ ] Bundle id registered and `DEVELOPMENT_TEAM` set.
- [ ] Icon regenerated; About panel shows your name, version and copyright.
- [ ] `App/PrivacyInfo.xcprivacy` still matches what your fork does (add entries if you add tracking/analytics or new required-reason APIs).
- [ ] Entitlements in `project.yml` (`App/Zikk.entitlements` is generated from them): sandbox, network client/server, user-selected files, bookmarks. Remove `network.server` only if you drop mock servers.
- [ ] Run the full test suite: `xcodebuild -scheme Zikk -destination 'platform=macOS' test`.
- [ ] Respect the licenses of bundled components (see *Third-party code* in `README.md`) and do not use the Zikk name or icon for your fork's branding.

## What changes for existing users

Changing `APP_BUNDLE_ID` gives the app a new sandbox container and Keychain namespace: workspaces, settings and stored
secrets from a build with another bundle id are not visible. Ship the new id from the first release.
