# Mobile contract fixtures

These fixtures are the shared wire-format baseline for the Go gateway, Swift client, and Kotlin client. They contain no real endpoint, path, token, account, or user content.

Rules:

- `manifest.json` records the frozen product commit and fixture purpose.
- REST payloads are ordinary JSON documents.
- App-server streams are NDJSON with one complete WebSocket text frame per line.
- Additive optional fields may be added without replacing older fixtures.
- A breaking field or semantic change requires a new fixture version and coordinated Go/Swift/Kotlin test updates.
- Secrets in fixtures must use the obvious `test-*` namespace and must never be accepted by production configuration.

