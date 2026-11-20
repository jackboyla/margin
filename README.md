# Margin

A native macOS reading assistant beside your cursor. Keep your paper in Chrome or Safari, ask about the current window, and return to your saved highlights and conversations later.

For macOS 26 or later. Answer with your signed-in [Codex CLI](https://github.com/openai/codex), [Claude Code](https://code.claude.com/docs/en/overview), or an OpenAI-compatible API. Your library saves locally in SQLite from the first launch.

## Demos

Recorded in Chrome on macOS 27.2 with a real local Qwen3 model through the API backend. The restart demonstration uses beta 2 and the other macOS recordings use beta 1. Click a preview to watch. Clips cut idle pauses; playback stays at normal speed.

| Ask beside the paper | Keep separate threads | Return to your notes |
| --- | --- | --- |
| [![Watch: open an arXiv PDF, save a highlight and ask a question](docs/media/margin-paper-question.jpg)](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-paper-question.mp4) | [![Watch: save another passage, compare highlights and browse threads](docs/media/margin-multiple-threads.jpg)](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-multiple-threads.mp4) | [![Watch: close the paper and app, restore highlights and continue a conversation](docs/media/margin-restore-library.jpg)](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.2/margin-restore-library.mp4) |

Also watch [a question with no text selected](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-window-context.mp4) and [starting a thread from a saved highlight](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.1/margin-saved-highlight.mp4).

The [beta 9 PDF highlight demo](https://github.com/jackboyla/margin/releases/download/v0.1.0-beta.9/margin-arxiv-highlights.mp4) shows two highlights added and removed on page four of an arXiv paper. This recording uses Chromium on Linux to show how the paper stays in place.

## Install

1. Download the DMG from [GitHub Releases](https://github.com/jackboyla/margin/releases).
2. Open the DMG, drag **Margin** to **Applications**, then open it from Applications.
3. In **Settings → Reading**, grant Device Control (Accessibility on macOS 26) and Screen Capture. macOS 27 calls the first permission **Device Control and Data Access**. Press **Control–Shift–H** to return to Margin after granting access. Allow Chrome or Safari Automation when macOS asks so Margin can associate notes with the page URL.
4. In Chrome, enable **View → Developer → Allow JavaScript from Apple Events** to keep webpage highlights attached to the text while scrolling. Margin paints saved passages inside the page; no extension is required.
5. In **Settings → Models**, choose Codex, Claude Code or an API provider and save your settings. Sign in to your chosen CLI first; API setup needs a model name and any required API key.

Ad-hoc beta builds are not notarized by Apple, and Gatekeeper may block them. If you trust the download, attempt to open it, then use **System Settings → Privacy & Security → Open Anyway** when macOS offers it. See [Apple's opening guidance](https://support.apple.com/en-us/102445) and check each release's signing notice.

Saving selected text requires Device Control (Accessibility on macOS 26), independently of Screen Capture. Enable the installed Margin app in **System Settings → Privacy & Security**. If it appears enabled but Margin still reports denied access, remove its permission entry and add the installed `Margin.app` again. Keep only one installed copy so the grant applies to the app you run.

## Use

- **Control–Shift–Space** starts a fresh question beside the pointer. Select text first to ask about that passage, or leave the selection empty to ask about the window. Continue existing conversations from the sidebar.
- **Control–Shift–N** opens a sticky note at the pointer in Chrome. Type and press **Command–Return** to save. You can also choose **Place sticky note…** from Margin’s menu and click the spot.
- In the sidebar’s **Notes** tab, select a note to edit, move or delete it. Choose **Move…**, click a new spot on the original page, then save. On regular webpages, pressing **Control–Shift–N** over an existing note opens it for editing.
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

Sticky notes, including their page positions, save in a local SQLite database. Document records, captured text, highlights, and conversations stay on this Mac, alongside window images. Codex and Claude Code keep their own session files. Existing JSON libraries migrate automatically. See [storage, migration, and backups](docs/storage.md).

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
- Chrome webpages paint highlights inside the page. On arxiv.org PDFs, Margin asks Chrome to display a locally annotated copy in the same tab. The address bar keeps the paper’s original URL. Before showing the copy, Margin checks the page number, zoom and positions of matching lines in both viewers. If it cannot verify your place or the passage occurs more than once, the passage stays available in the sidebar. This requires JavaScript from Apple Events and macOS Accessibility. Other PDFs and apps use native overlays, which can lag during scrolling. Frames, math, columns and scanned pages can prevent painting.
- Sticky notes support ordinary HTTP(S) webpages in Chrome and readable arXiv PDFs in Chrome’s built-in viewer. On a webpage, notes follow their page element when possible and fall back to their saved page coordinates. A note on an embedded frame follows its outer box when the main page scrolls. PDF placement requires identifiable text on the page. Notes on browser settings pages, other PDFs, and rotated or image-only PDF pages are unsupported.
- Chrome and Safari page identity uses their URL. Other apps depend on the document URL they expose or their window title; changed titles can create separate records.
- Each arXiv paper version has its own identity. HTML, abstract, and PDF URLs for the same identifier share a library entry; unrelated query parameters and fragment routes remain significant.
- Shortcuts are fixed.
- API conversations use streaming Chat Completions. Read-only agent tools are available through Codex and Claude Code; direct API conversations require a model that answers with text.

## Structure

`MarginCore` owns the library and document identity. `Margin` owns native windows, global shortcuts, source capture, and the agent process. The UI persists requests before starting execution and retains the source context with each question.

MIT licensed. Interaction references: [My-Monkey's OpenSuperWhisper](https://github.com/my-monkeys/OpenSuperWhisper) and [T3 Code](https://github.com/pingdotgg/t3code).
