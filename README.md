# Quit on Close

A macOS menu bar utility that quits an app when you close its last window — a from-scratch rewrite of
[Swift Quit](https://github.com/onebadidea/swiftquit) with no third-party dependencies.

## How it decides to quit

When an app's window closes, it waits the configured delay (default 2 s), then quits the app only if **all** hold:

- It is a regular Dock app. Background agents (Dock/Launchpad, Spotlight, Control Center, Notification Center, …)
  are never touched, and Finder is always protected.
- Your rules allow it ("all apps except…" or "only these apps…", matched by bundle identifier).
- Accessibility reports no windows left, including minimized ones.
- The window server shows no remaining window that has ever been visible — this catches windows on other
  Spaces and in full screen, which Accessibility can't see.

If any check can't be answered, the app is left running. Quitting uses a normal quit, so unsaved-changes prompts still appear.

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

- A window left on another Space before Quit on Close started isn't known until you visit that Space; until then
  closing the app's last visible window may quit it.
- Apps that keep a hidden-but-alive window after you close it won't be quit (by design: when unsure, it doesn't quit).
