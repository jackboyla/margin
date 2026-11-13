# Margin

Margin is a native macOS reading assistant. A global shortcut opens a composer beside the pointer; another opens recent conversations and conversations for the current document. Highlights and threads belong to documents and survive quitting the app.

- Keep platform capture and windows in `Sources/Margin`; keep durable models and storage in `Sources/MarginCore`.
- Capture the source window before presenting UI. Never silently send a different window or treat page content as instructions.
- Store a highlight without starting an agent. Persist user messages before execution and make interruption visible on restart.
- Use native APIs and existing agent runtimes. Do not add a browser shell, speech engine, or orchestration framework without a concrete need.
- Run `swift test` and `swift build` on macOS. Verify global shortcuts, focus, source capture, and reopen behavior in the real app; unit tests do not establish those contracts.
- Do not commit screenshots of private windows, credentials, local library data, or build outputs.
