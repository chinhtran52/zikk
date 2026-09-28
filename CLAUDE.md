# Zikk

Native macOS (26+) Postman-like API client, product name **Zikk**, bundle id `dev.chinhtr.zikk`. SwiftUI + AppKit bridges only; no third-party UI libraries.
Distribution target: Mac App Store (App Sandbox on).

## Layout

- `project.yml` — XcodeGen spec (the `.xcodeproj` is generated and git-ignored). Run `xcodegen generate` after adding targets/files.
- `Config/Branding.xcconfig` — name, bundle id, URL scheme, version, team. Read at runtime via `APICore/Branding.swift`; never hardcode the product name or bundle id (see `whitelabel.md`).
- `App/` — thin app target (`ZikkApp.swift`, entitlements, assets).
- `Packages/ZikkKit/` — all logic as SwiftPM targets:
  - `APICore` value types (`RequestSpec`, `AuthConfig`, `VariableResolver`, `RawURL`, `JSONFormatter`)
  - `APIStore` SwiftData models (Codable structs stored as JSON `Data` columns), `SecretStore` (Keychain)
  - `HTTPEngine` request builder, auth signers, cookie jar, `HTTPClient`, OAuth2
  - `HTTPServer` small NWListener HTTP/1.1 server (tests + mock server)
  - `ScriptEngine` JavaScriptCore sandbox with Postman `pm.*` API (`Resources/sandbox.js`, bundled chai/lodash/crypto-js/moment)
  - `Execution` request pipeline: pre-request scripts → send → test scripts → variable merge
  - `Interop` Postman v2.x collection/environment + cURL; `CodeGen` snippets
  - `SpecKit` OpenAPI 3.x / Swagger 2.0: Yams-based parser with source lines, validator, importer/exporter, sync diff,
    JSON Schema + contract validation. (OpenAPIKit was deliberately not used: it cannot report line numbers or validate instances.)
  - `Runner` collection runner, datasets (CSV/JSON), reports (JSON/JUnit), performance runner
  - `Docs` safe Markdown → HTML renderer (swift-markdown's HTMLFormatter does not escape text) and documentation generator
  - `MockServer` mock matching/templating on top of `HTTPServer`
  - `RealtimeEngine` WebSocket (URLSessionWebSocketTask), SSE client/parser, GraphQL introspection
  - `ProtoKit` `.proto` parser + dynamic protobuf ⇄ JSON codec; `GRPCEngine` dynamic gRPC client (grpc-swift-2, NIO Transport Services) + server reflection
  - `DesignSystem` reusable views (`CodeEditor` = NSTextView); `Features` app screens
- `UITests/` — XCUITest (runner has network entitlements so tests can start an `HTTPServer`).
- `Localization/vi.json` + `scripts/sync_strings.py` — Vietnamese translations.

## Commands

- Package build/test (fast): `scripts/build.sh build`, `scripts/build.sh test [--filter X]`
- App + all tests: `xcodegen generate && xcodebuild -scheme Zikk -destination 'platform=macOS' -derivedDataPath build/DerivedData test`
- Strings: UI strings use `L("…")` (module-local helper, `Bundle.module`). After adding strings run `python3 scripts/sync_strings.py --check` and add missing keys to `Localization/vi.json`.

## Gotchas

- The main `WindowGroup` uses `.restorationBehavior(.disabled)`: AppKit state restoration could restore "zero windows" and leave the app windowless (seen in UI tests and after quitting with no window). Tabs are restored by `SessionSnapshot` instead. UI tests use `-ui-testing` (wipes app defaults, in-memory store).
- Avoid AppKit-backed split views (`HSplitView`, `VSplitView`, `.inspector`) inside the `NavigationSplitView` detail: they caused layout loops ("more Update Constraints passes than views") when resizing. Use `ResizableHSplit`/`ResizableVSplit` from DesignSystem; `LayoutTests` guards this.
- Xcode string-catalog symbol generation rejects many keys; the sync script writes `"generatesSymbol": false` per entry.
- SwiftUI `.accessibilityIdentifier` does not reach the `NSTextView` inside `CodeEditor`; pass `identifier:` instead.
- Hardened runtime is Release-only; with ad-hoc signing it breaks UI test bundle loading in Debug.
- Secret variables are persisted blank in SwiftData; values live in `SecretStore` keyed `"<scopeID>.<variableID>"` (see `SecretVariables`).
- `RequestSpec` has a hand-written tolerant `init(from:)`; add new fields there with defaults so stored data keeps decoding.
- App icon is generated: `swift scripts/make_icon.swift` (do not use SF Symbols in the icon — license).
- Git commits: no Co-Authored-By trailer.
