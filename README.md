# Margin

A native macOS reading assistant beside your cursor. Keep your paper in Chrome or Safari, ask about the current window, and return to your saved highlights and conversations later.

Early prototype for macOS 14 or later. Uses your installed, signed-in [Codex CLI](https://github.com/openai/codex).

## Use

- **Option–backtick** opens a question box beside the pointer. Select text before opening it, or leave the selection empty to ask about the window.
- Select more text in the source window and return to the box to include that passage. The source page stays pinned; changing pages requires capturing the new page.
- The **highlighter** button saves the selected passage without contacting the agent.
- **Option–Shift–backtick** opens recent conversations, conversations for this page, and its saved highlights.
- **Ask about this** starts a conversation from a saved highlight. Follow-ups resume that conversation's Codex session.
- **Escape** closes the panel. **Stop** interrupts the agent request.

Margin combines accessible text, text recognition, and an image of the chosen window. The agent also receives saved highlights for that document. A window capture does not contain the unread pages of an entire paper.

## Build

Install Xcode with its macOS SDK and Swift 6 or later, then:

```sh
swift test
bash scripts/build-app.sh
open dist/Margin.app
```

The build creates an ad-hoc signed app, not a notarized distribution. Keep it at a stable path when granting permissions. The first launch explains Accessibility, Screen Recording, and browser Automation access, which let Margin read selections, capture the chosen window, and identify its webpage.

Settings lets you choose the Codex executable and working folder. Sign in with `codex login` first. The prototype uses read-only agent tools; requests that require writing files are outside this version's scope.

## Local storage

The library lives in `~/Library/Application Support/Margin/`. `library.json` contains documents, highlights, conversations, captured text, and Codex session IDs. `Attachments/` holds window images. Back up this directory to retain your reading history; Codex stores its sessions separately in its normal home directory. Highlights do not require an agent session.

Writes replace the library atomically. An interrupted reply stays marked as interrupted after restart and does not restart itself. A corrupt or unsupported library produces an error rather than being replaced with an empty one.

## Current limits

- Restored highlights mark visible text lines using text recognition. They do not modify the webpage or PDF. A quote must match uniquely; missing or repeated text stays unpainted and remains in the sidebar. Math, columns, and scanned PDFs can defeat matching.
- Chrome and Safari page identity uses their URL. Other apps depend on the document URL they expose or their window title; changed titles can create separate records.
- Each arXiv paper version has its own identity. HTML, abstract, and PDF URLs for the same identifier share a library entry; unrelated query parameters and fragment routes remain significant.
- The shortcuts use the physical backtick key. Shortcut customization and cross-device sync are not included.

## Structure

`MarginCore` owns the library and document identity. `Margin` owns native windows, global shortcuts, source capture, and the agent process. The UI persists requests before starting execution and retains the source context with each question.

MIT licensed. Interaction references: [My-Monkey's OpenSuperWhisper](https://github.com/my-monkeys/OpenSuperWhisper) and [T3 Code](https://github.com/pingdotgg/t3code).
