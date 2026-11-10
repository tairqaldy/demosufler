# demosufler

A teleprompter for macOS. A black panel sits under the MacBook camera and scrolls your script while the
app records the camera, the screen, or both. The panel stays above every window on every desktop and
never shows up in the recording.

Download: <https://github.com/tairqaldy/demosufler/releases/latest/download/demosufler.dmg>
(macOS 15 or newer, Apple silicon and Intel). The interface is in English, Russian can be switched on
from the first screen or later from the panel.

Русский: demosufler — телесуфлер для macOS. Текст едет под камерой, приложение пишет камеру, экран или
оба сразу, а в режиме «Ролик» само собирает готовое видео. Язык интерфейса переключается на панели.

## Install

One command in Terminal downloads the latest version into Applications and starts it, without the
macOS warning about an unknown developer:

```bash
curl -fsSL https://raw.githubusercontent.com/tairqaldy/demosufler/main/install.sh | bash
```

Or by hand:

1. Open `demosufler.dmg` and drag demosufler to Applications.
2. Start it. macOS says it cannot check the developer, because the app is not notarized by Apple.
3. Open System Settings → Privacy & Security and press "Open Anyway" at the bottom.
4. The panel then walks you through the permissions: camera and microphone with one button, screen
   recording through System Settings and a Restart button.

## Using it

- **Mode** (left): `Camera` writes one file, `Both` writes camera and screen as two files in parallel,
  `Screen` writes the screen only, `Launch` writes the screen and builds a finished video (see below).
- **Record** (or ⌘R): a three second countdown, then recording and scrolling from the top. Press again
  to stop.
- **Speed** shows how long the whole text takes. The ↑ and ↓ keys change it while you read.
- **Transparency** fades the background of the panel, the text stays bright.
- **Space** pauses the scroll, the trackpad moves the text by hand.
- **Pencil** opens the text for editing. Lines in `[brackets]` and lines starting with `#` are dimmed
  cues.
- Files land in `~/Movies/demosufler/` (`…_camera.mov`, `…_screen.mov`, `…_launch.mp4`).
- The panel has no Dock icon. Quit it with the × on the panel, from its menu bar icon, or with ⌘Q.
- Shortcuts work while the panel was the last thing you clicked.

### Launch mode

Record the screen as usual. When you press Stop the app renders an `.mp4` by itself: the recording sits
on a clean background with rounded corners and a shadow, every click leaves a ripple, and the camera can
sit in the corner as a round bubble. The raw files stay next to the result.

The camera work follows what you do, not where the pointer happens to be:

- The whole screen is the default. The view moves in only for an action: a click or a drag.
- Clicks close together in time and place become one shot, framed so that all of them are visible.
- During a shot the view does not chase the pointer. It follows it only while you drag something.
- A moment after the last action, or as soon as the pointer leaves the picture, the view goes back to
  the whole screen. Going straight to a distant area, it pulls back on the way.
- Quick clicks all over the screen are shown on the whole screen, and the view moves in again where you
  settle.

`./build/demosufler-dev --plan <track.json> <seconds>` prints the shots for a pointer track.

### Sound

The microphone is opened only for a recording, starting with the countdown. If the system input is a
pair of Bluetooth headphones the app records from the Mac's own microphone instead, because opening a
Bluetooth microphone drops the headphones into low quality "call" sound.

## Updates

On launch the app asks GitHub for the latest release of this repository. If it is newer, a bar appears
at the bottom of the panel with an Update button: the app downloads `demosufler.zip` from the release,
checks its signature, replaces itself and restarts.

There is no paid Apple developer account behind the app, so it is not notarized. It is signed with
its own self-signed certificate instead, the same one for every release since 1.1.3. macOS ties camera,
microphone and screen recording permissions to that signature, so they are asked once and kept across
updates. (Updating from a version before 1.1.3 asks one last time.) The updater also refuses any build
that is not signed with this certificate.

## Building

Only the Command Line Tools are needed (`xcode-select --install`), not Xcode.

```bash
./build.sh
```

builds `build/demosufler.app`.

Releases are signed with a private identity that lives outside the repository, in
`~/Library/Application Support/demosufler-signing` (`tools/make_signing_identity.sh` creates it,
`tools/sign.swift` signs with it, no keychain is involved). Keep that folder backed up: with a different
identity macOS treats the app as a new one and asks everybody for the permissions again. Without the
folder `build.sh` still works and gives the build a one-off local signature.

To publish an update:


1. Raise the number in `VERSION` and commit.
2. Run `./release.sh`. It builds the app, packs `dist/demosufler.zip` and `dist/demosufler.dmg`, pushes
   the branch and creates the release `v<version>` with `gh`.

`./release.sh --no-publish` only builds `dist/`.

### Tests and the product video

`./tools/dev.sh` builds `build/demosufler-dev`, the same code as a plain binary with a few commands:

```bash
./build/demosufler-dev --selftest /tmp/demosufler-test
```

records the screen for a few seconds with the pointer tracker running, renders a launch video from it
and checks the result. `--probe <file>` prints the tracks of a video, `--frame <file> <seconds> <png>`
saves one frame, `--render` runs the launch renderer on an existing recording.

`python3 tools/demo/make_demo.py <folder>` makes the video on the landing page: the app plays a scripted
timeline on a clean backdrop, hidden behind the desktop picture, records only its own windows and
renders the result with the Launch renderer. The narration lines are in `tools/demo/narration.txt`.

## Layout

| File | What it does |
|---|---|
| `Sources/App.swift` | the panel above all windows, hidden from capture; shortcuts; menu bar icon; watchdog |
| `Sources/Model.swift` | state, scrolling, countdown, starting and stopping recordings |
| `Sources/Recorder.swift` | camera through AVFoundation, screen through ScreenCaptureKit, microphone choice |
| `Sources/CursorTrack.swift` | pointer positions and clicks during a Launch recording |
| `Sources/LaunchRenderer.swift` | zooms, background, ripples, camera bubble, writing the `.mp4` |
| `Sources/Updater.swift` | GitHub release check and self-replacement |
| `Sources/Views.swift` | the interface (SwiftUI, the prompter text itself is drawn with AppKit) |
| `Sources/L10n.swift` | English and Russian strings |
| `Sources/Demo.swift`, `Sources/Tools.swift` | scripted demo and command line helpers |
| `tools/sign.swift`, `tools/make_signing_identity.sh` | signing with the app's own certificate |
| `landing/` | the landing page, one static file plus the video |
