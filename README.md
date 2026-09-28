# Zikk

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)

Zikk is a native macOS (26+) API client in the spirit of Postman, built with SwiftUI and no third-party UI libraries.
Local-first: all data lives in SwiftData on your Mac, secrets in the Keychain.

## Features

| Area | What you get |
|---|---|
| **Requests** | HTTP (params, headers, raw/form-data/urlencoded/binary/GraphQL bodies), cookies, redirects, TLS options, timing breakdown, history |
| **Protocols** | HTTP/1.1 & HTTP/2, GraphQL (schema explorer via introspection), WebSocket, Server-Sent Events, gRPC (unary + all streaming kinds, `.proto` or server reflection) |
| **Auth** | Basic, Bearer, API Key, Digest, OAuth 1.0, OAuth 2.0 (Auth Code + PKCE, Client Credentials, Password), AWS SigV4, inheritance collection → folder → request |
| **Collections** | Folders, drag & drop, duplication, saved examples, collection/folder auth, scripts and variables; search that expands matching folders and highlights the match |
| **Environments** | Environments + globals, secret values in the Keychain, `{{variables}}` and Postman dynamic variables; variables in the URL bar are highlighted (red when undefined) and show their current value on hover |
| **Scripts** | Pre-request and post-response JavaScript (JavaScriptCore) with a Postman-compatible `pm.*` API, `pm.test`/`pm.expect` (chai), `pm.sendRequest`, `require()` of lodash, crypto-js, moment |
| **Collection Runner** | Iterations, CSV/JSON datasets, delays, `setNextRequest`, stop on failure, JSON/JUnit reports, performance mode (virtual users, p50/p90/p95/p99, error rate, chart) |
| **APIs (Specs)** | OpenAPI 3.x / Swagger 2.0 editor with line-level diagnostics and outline, native docs preview, generate/sync collections, contract testing of responses |
| **Documents** | Markdown descriptions, generated documentation per collection with code samples, single-file HTML export |
| **Mock servers** | Local HTTP mocks from collection examples or spec examples, Postman-style matching (`x-mock-response-name/code`), templating, delays, CORS, live request log |
| **Interop** | Import/export Postman Collection v2.1 and environments, OpenAPI import/export, cURL import (paste into the URL bar) and code generation (cURL, HTTP, Swift, JS fetch/axios, Python, Go, Java/Kotlin OkHttp) |
| **App** | Tabs with session restore, console window, settings (proxy, mTLS client certificates, timeouts), English + Vietnamese |

## Building

Requirements: macOS 26, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Zikk.xcodeproj                 # or:
xcodebuild -scheme Zikk -destination 'platform=macOS' build
```

Tests:

```sh
scripts/build.sh test               # fast: all Swift package tests
xcodebuild -scheme Zikk -destination 'platform=macOS' -derivedDataPath build/DerivedData test   # + UI tests
```

For App Store distribution set `DEVELOPMENT_TEAM` in `Config/Branding.xcconfig`; the app is sandboxed with network client/server and user-selected file entitlements.

## White-labelling

Rebrand the app (name, bundle id, icon, signing) by editing `Config/Branding.xcconfig` — see [whitelabel.md](whitelabel.md).

## Project layout

See [CLAUDE.md](CLAUDE.md) for the module map and development notes, and [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next.

## Contributing

Issues and pull requests are welcome. Please run `scripts/build.sh test` and `python3 scripts/sync_strings.py --check` before opening a PR.

## Third-party code

- Swift packages: Yams, swift-markdown, grpc-swift-2, grpc-swift-nio-transport, swift-protobuf (and their dependencies).
- Bundled JavaScript for scripts (MIT): chai 4.5.0, lodash 4.17.21, crypto-js 4.2.0, moment 2.30.1.

## License

Zikk is released under the [MIT License](LICENSE). Bundled third-party code keeps its own license.
