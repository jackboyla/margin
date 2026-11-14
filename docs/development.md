# Development and isolated testing

Run `swift test` and `bash scripts/build-app.sh` on a Mac with Xcode and Swift 6. The GitHub Actions workflow runs both. Keep interactive acceptance tests in a full macOS guest when the host Mac is in use: a Space or another Screen Sharing login is not a reliable boundary for display and input changes.

## Test guest

Install [Tart](https://tart.run/quick-start/) on an Apple Silicon Mac. The helper uses a project-local, ignored VM store and disables automatic cache pruning. It creates a Sonoma 14.6.1 guest with two CPU cores, 4 GB RAM, and a fixed 1280 × 800 logical display. Allow at least 35 GiB free before creation; the guest continues to consume disk space after stopping.

```sh
bash scripts/test-vm.sh create
bash scripts/test-vm.sh run
# In another shell:
bash scripts/test-vm.sh ip
# When finished:
bash scripts/test-vm.sh stop
```

Set `TART_BIN` if Tart is outside `PATH`. The run command stays in the foreground; use a persistent terminal session for remote work. It disables host graphics, clipboard, audio and USB pass-through, and prints the guest VNC endpoint and password. Keep that output private. Connect to this guest endpoint through an SSH tunnel; leave host Screen Sharing off. Change the image's default guest password before adding credentials. Confirm `sysctl -n hw.model` reports `VirtualMac2,1` inside the guest before running input automation.

Copy `dist/Margin.app` to a stable path such as `~/Applications/Margin.app` **inside the guest**. Install and sign in to Codex there, choose its executable in Margin settings, and grant Accessibility, Screen Recording and Safari/Chrome Automation inside the guest. Do not reuse a signed-in VM as a public image. Stop the guest when tests finish to release its memory and CPU allocation.

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
3. Open Control–Shift–H. Check Recent, This page and Highlights. Ask about a saved highlight, send a follow-up, and start another thread. Follow-ups must retain their agent session; independent threads must have different sessions.
4. Close and reopen the paper tab, then quit and reopen Margin. Check both the sidebar records and restored visible highlights. Saved records alone do not prove overlay restoration.
5. Repeat selection and hotkey capture while highlight refreshes occur. Capture must finish, and changing conversations during capture must remain disabled. Check that long answers scroll while the composer header and question field remain visible.

The local library and Codex session files provide persistence evidence. Keep test output and screenshots outside the repository; distinguish real agent answers from fixtures when reporting results.
