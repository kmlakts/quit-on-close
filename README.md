# Quit on Close

A macOS menu bar utility that quits an app when you close its last window — a from-scratch rewrite of
[Swift Quit](https://github.com/onebadidea/swiftquit) with no third-party dependencies.

## How it decides to quit

When an app's window closes — or its last visible window disappears, which catches apps like Claude,
ChatGPT or Slack that hide their window instead of closing it — it waits the configured delay (default 2 s), then quits the app only if **all** hold:

- It is a regular Dock app. Background agents (Dock/Launchpad, Spotlight, Control Center, Notification Center, …)
  are never touched, and Finder is always protected.
- Your rules allow it ("all apps except…" or "only these apps…", matched by bundle identifier).
- Accessibility reports no windows left, including minimized ones.
- The window server shows no remaining window that has ever been visible and is still open. A window parked
  on another Space or in full screen counts as open (Accessibility can't see those); a window hidden by the
  app, off screen on the current Space, counts as closed.
- The app isn't hidden (⌘H), which also takes all its windows off screen.

If any check can't be answered, the app is left running.
The window server can't tell a minimized window from a hidden one; Accessibility can, so minimized windows keep the app open. Quitting uses a normal quit, so unsaved-changes prompts still appear.

## Install

1. Download the latest `QuitOnClose-vX.Y.Z.zip` from [Releases](https://github.com/kmlakts/quit-on-close/releases), unzip it,
   and move **Quit on Close.app** to `/Applications`.
2. Open it. macOS will say it can't verify the app, because it's self-signed rather than notarized by Apple.
   Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   (Or run `xattr -dr com.apple.quarantine "/Applications/Quit on Close.app"`.) This is needed only once.
3. Allow it under **System Settings → Privacy & Security → Accessibility** when asked.

Updates: quit the app, replace it in `/Applications`, open it again. Every release is signed with the same certificate,
so the Accessibility permission and your settings carry over.

Requires macOS 14 or later, on Apple Silicon or Intel.

## Build from source

Requires the Xcode Command Line Tools (full Xcode not needed for a build for your own Mac).

```sh
./build.sh                       # → build/Quit on Close.app
cp -R "build/Quit on Close.app" /Applications/
```

Without the release certificate the build is ad-hoc signed, so macOS treats each rebuild as a new app: remove and re-add
it under Accessibility after replacing it. Set `SIGN_IDENTITY` to your own code-signing certificate to avoid that.

## Releasing

Releases are built and signed by GitHub Actions (`.github/workflows/release.yml`) when a version tag is pushed:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

The workflow needs two repository secrets, made from the self-signed certificate:

- `SIGNING_P12`: `base64 -i signing.p12`
- `SIGNING_P12_PASSWORD`: the .p12 password

Keep the .p12 and its password backed up and private. Releases signed with a different certificate make every user
re-grant Accessibility.

## Known limits

- Hiding the window on close usually means "keep running in the background". Chat apps such as Slack, Discord,
  Teams and WhatsApp do it too, so they are quit and stop delivering notifications. A notice on first launch
  says so. Add any you want kept running to **Never quit**.

- A window left on another Space before Quit on Close started isn't known until you visit that Space; until then
  closing the app's last visible window may quit it.
- Telling hidden windows from windows on other Spaces uses undocumented window-server calls (the same ones yabai
  and AltTab use). If a future macOS removes them, hidden windows count as open and those apps stay running.
