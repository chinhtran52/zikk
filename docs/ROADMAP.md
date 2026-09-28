# Roadmap

## Phase 1 — local app (done)

M0 foundation · M1 HTTP core · M2 collections & interop · M3 scripting · M4 datasets & runner · M5 OpenAPI specs ·
M6 documents · M7 mock servers · M8 GraphQL/WebSocket/SSE · M9 gRPC · M10 polish (settings, session restore, icon, privacy manifest).

## Phase 2 — cloud (TODO)

The data model is sync-ready: every SwiftData model has `id`, `createdAt`, `updatedAt`, `deletedAt` (tombstones) and `revision`.

- [ ] Account & login (Sign in with Apple, email, SSO/SAML)
- [ ] Backend sync of workspaces, collections, environments, specs, datasets and mocks; offline-first with conflict resolution (revision-based, field-level merge for requests)
- [ ] Teams and shared workspaces; roles & permissions; invitations
- [ ] Comments on requests/collections, activity feed, change history, fork & merge of collections
- [ ] Hosted public documentation with custom domains
- [ ] Cloud mock servers and scheduled monitors (collection runs in the cloud) with alerts
- [ ] API versioning & releases; governance/lint rules for specs
- [ ] Team secret vault and audit log
- [ ] Command-line runner (newman-like) reusing the `Runner`/`Execution` packages
- [ ] Optional personal iCloud sync via CloudKit

## Known gaps in Phase 1

- GraphQL: schema explorer with "Insert", no inline autocomplete in the query editor.
- Code editor: no line-number gutter or autocompletion.
- Scripts: a synchronous infinite loop cannot be interrupted (the run stops waiting after the timeout); `pm.visualizer` output is captured but not rendered; `xml2Json` is unavailable.
- Collection runner results are exported (JSON/JUnit) but not stored in the database.
- Postman export writes WebSocket/SSE/gRPC requests as plain HTTP requests (the Postman format has no equivalent).
- Mock servers listen on the loopback interface only.
- OAuth 2.0 implicit grant and OAuth 1.0 RSA-SHA1 are not supported.
- `.proto` import: a single source (plus well-known types); multi-file imports should use server reflection. Proto2 groups/extensions are not supported.
