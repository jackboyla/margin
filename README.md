# Margin

A native macOS reading assistant beside your cursor. Keep your paper in Chrome or Safari, ask about the current window, and return to your saved highlights and conversations later.

For macOS 26 or later. Answer with your signed-in [Codex CLI](https://github.com/openai/codex), [Claude Code](https://code.claude.com/docs/en/overview), or an OpenAI-compatible API. Your library saves locally in SQLite from the first launch.

## Demos

Recorded in Chrome on macOS 27.2 with a real local Qwen3 model through the API backend. The restart demonstration uses beta 2; the other clips use beta 1. Click a preview to watch. Clips cut idle pauses; playback stays at normal speed.

| Ask beside the paper | Keep separate threads | Return to your notes |
| --- | --- | --- |
| [![Watch: open an arXiv PDF, save a highlight and ask a question](docs/media/margin-paper-question.jpg)](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-paper-question.mp4) | [![Watch: save another passage, compare highlights and browse threads](docs/media/margin-multiple-threads.jpg)](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-multiple-threads.mp4) | [![Watch: close the paper and app, restore highlights and continue a conversation](docs/media/margin-restore-library.jpg)](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.2/margin-restore-library.mp4) |

Also watch [a question with no text selected](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-window-context.mp4) and [starting a thread from a saved highlight](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-saved-highlight.mp4).

## Install

1. Download the DMG from [GitHub Releases](https://github.com/jackboyla/margin/releases).
2. Open the DMG, drag **Margin** to **Applications**, then open it from Applications.
3. In **Settings → Reading**, grant Device Control (Accessibility on macOS 26) and Screen Capture. macOS 27 calls the first permission **Device Control and Data Access**. Press **Control–Shift–H** to return to Margin after granting access. Allow Chrome or Safari Automation when macOS asks so Margin can associate notes with the page URL.
4. In **Settings → Models**, choose Codex, Claude Code or an API provider and save your settings. Sign in to your chosen CLI first; API setup needs a model name and any required API key.

Ad-hoc beta builds are not notarized by Apple, and Gatekeeper may block them. If you trust the download, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** when macOS offers it. See [Apple's opening guidance](https://support.apple.com/en-us/102445) and check each release's signing notice.

Saving selected text requires Device Control (Accessibility on macOS 26), independently of Screen Capture. Enable the installed Margin app in **System Settings → Privacy & Security**. If it appears enabled but Margin still reports denied access, remove its permission entry and add the installed `Margin.app` again. Keep only one installed copy so the grant applies to the app you run.

## Use

- **Control–Shift–Space** starts a fresh question beside the pointer. Select text first to ask about that passage, or leave the selection empty to ask about the window. Continue existing conversations from the sidebar.
- **Control–Shift–S** saves the selected passage without opening a conversation or contacting a model. A brief confirmation appears beside the pointer.
- Drag the question box by its header to move it.
- You can type and press **Ask** while page context loads; Margin waits for the verified source before contacting the model.
- Select more text in the source window and return to the box to include that passage. The source page stays pinned; changing pages requires capturing the new page.
- The **highlighter** button saves the selected passage without contacting the agent.
- **Control–Shift–H** opens the sidebar: search recent conversations, view this page's threads, browse saved highlights from any page, or open Settings.
- **Ask about this** starts a conversation from a saved highlight. Open a thread in the sidebar to continue it. Codex and Claude Code threads keep their own agent session; API threads retain their conversation history. Click a thread’s source link to reopen its page.
- Click the **model name** below the question field to choose a model for this conversation. **Use as default** saves it for new threads; configure the provider and key in **Settings → Models**.
- **Escape** closes the panel. **Stop** interrupts the agent request.

Questions include captured text and the document's saved highlights. CLI agents also receive the available window image; API images require opting in for a vision model. A window capture covers the chosen window, not the unread pages of an entire paper.

The API presets cover OpenAI, Claude's OpenAI compatibility endpoint, Ollama, and LM Studio. Enter an explicit model name; image and streaming support depend on the model and server. API keys stay in macOS Keychain. See [provider setup](docs/providers.md).

## Library

Notes save immediately in a local SQLite database. Document records, captured text, highlights, and conversations stay on this Mac, alongside window images. Codex and Claude Code keep their own session files. Existing JSON libraries migrate automatically. See [storage, migration, and backups](docs/storage.md).

## Build

On macOS 26 or later, install Xcode 26.3 or later with its macOS SDK and Swift 6.2 or later, then:

```sh
swift test
bash scripts/build-app.sh
open dist/Margin.app
```

Builds use ad-hoc signing by default. Keep the app at a stable path when granting permissions; ad-hoc rebuilds can require granting them again. See [development and isolated testing](docs/development.md) for repeated builds and [release packaging](docs/releases.md) for universal DMGs, Developer ID signing, and notarization.

## Current limits

- The PDF workflow is tested in Chrome. Safari PDF text selection is not yet verified on macOS 26 or later.
- Restored highlights use native text positions in Chromium browsers, with text recognition as a fallback. They do not modify the webpage or PDF. Native ranges follow the text during scrolling; image-only highlights refresh after scrolling stops. A quote must match uniquely; missing, repeated or partial OCR words stay unpainted and remain in the sidebar. Math, columns, and scanned PDFs can defeat matching.
- Chrome and Safari page identity uses their URL. Other apps depend on the document URL they expose or their window title; changed titles can create separate records.
- Each arXiv paper version has its own identity. HTML, abstract, and PDF URLs for the same identifier share a library entry; unrelated query parameters and fragment routes remain significant.
- Shortcuts are fixed.
- API conversations use streaming Chat Completions. Read-only agent tools are available through Codex and Claude Code; direct API conversations require a model that answers with text.

## Structure

`MarginCore` owns the library and document identity. `Margin` owns native windows, global shortcuts, source capture, and the agent process. The UI persists requests before starting execution and retains the source context with each question.

MIT licensed. Interaction references: [My-Monkey's OpenSuperWhisper](https://github.com/my-monkeys/OpenSuperWhisper) and [T3 Code](https://github.com/pingdotgg/t3code).
