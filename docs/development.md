# Development and isolated testing

Run `swift test` and `bash scripts/build-app.sh` on macOS 26 or later with Xcode 26.3 or later and Swift 6.2 or later. GitHub Actions runs the tests and packages a DMG on `macos-26` with Xcode 26.3 to cover the minimum supported system. For interactive acceptance, use a guest matching the macOS version being tested. A full guest isolates display and input changes while the host Mac is in use; a Space or another Screen Sharing login does not provide that isolation.

## Test guest

Install [Tart](https://tart.run/quick-start/) on an Apple Silicon Mac. The helper creates a macOS 27.2 guest with two CPU cores, 4 GB RAM, and a fixed 1280 × 800 logical display. It uses a project-local, ignored VM store and disables automatic cache pruning. Allow at least 40 GiB free before creation; the guest continues to consume disk space after stopping.

```sh
bash scripts/test-vm.sh create
bash scripts/test-vm.sh run
# In another shell:
bash scripts/test-vm.sh ip
# When finished:
bash scripts/test-vm.sh stop
```

Set `TART_BIN` if Tart is outside `PATH`. The run command stays in the foreground; use a persistent terminal session for remote work. It disables host graphics, clipboard, audio and USB pass-through, and prints the guest VNC endpoint and password. Keep that output private. Connect to this guest endpoint through an SSH tunnel; leave host Screen Sharing off. Change the image's default guest password before adding credentials. Confirm `sysctl -n hw.model` reports `VirtualMac2,1` inside the guest before running input automation.

Copy `dist/Margin.app` to a stable path such as `~/Applications/Margin.app` **inside the guest**. Configure a [model provider](providers.md) there, and grant the window permissions requested in Margin's Reading settings, plus Safari/Chrome Automation, inside the guest. Do not reuse a VM containing sign-in credentials as a public image. Stop the guest when tests finish to release its memory and CPU allocation.

## Signing repeated builds

Ad-hoc signatures change when the executable changes, which can invalidate macOS privacy grants. Use the same code-signing identity and installation path for repeated builds:

```sh
CODE_SIGN_IDENTITY="Your development signing identity" bash scripts/build-app.sh
```

`CODE_SIGN_KEYCHAIN` optionally selects a dedicated keychain. Unlock it before building. The script defaults to ad-hoc signing when no identity is supplied. Keep signing keys, passwords, Codex credentials and VM disks out of Git. A local development signature does not provide notarization for distribution.

## Browser acceptance trial

Use a public arXiv paper in the guest's existing browser. Exercise the actual app and agent, not a substituted response:

1. Press Control–Shift–Space without selecting text, type immediately, and ask about the visible page. Confirm the source and answer match it. Escape should return keyboard use to the browser; Option–backtick must not open Margin.
2. Select passages, open the composer and save several highlights without asking questions. Check the quoted text and painted lines. Scroll, switch apps, and change pages; highlights must not remain over unrelated content.
3. Open Control–Shift–H. Check Recent, This page, Highlights and search. Ask about a saved highlight, send a follow-up in the sidebar, and start another thread. With Codex, follow-ups must retain their agent session and independent threads must have different sessions. With an API backend, check that follow-ups retain prior messages and the selected model.
4. Close and reopen the paper tab, then quit and reopen Margin. Check both the sidebar records and restored visible highlights. Saved records alone do not prove overlay restoration.
5. Repeat selection and hotkey capture while highlight refreshes occur. Capture must finish, and changing conversations during capture must remain disabled. Check that long answers scroll while the composer header and question field remain visible.

Exercise provider settings in the app as well as the core tests: save and reload a Keychain credential and use a text-only model with images disabled. Test failure and interruption with the real service you intend to use; a mock server does not establish hosted-provider compatibility. Check [JSON migration and backups](storage.md) against a copy of a local library.

The SQLite library and Codex session files provide persistence evidence. Keep test output and screenshots outside the repository; distinguish real model answers from fixtures when reporting results.
