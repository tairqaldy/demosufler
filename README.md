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
on a clean background with rounded corners and a shadow, the view zooms in on your clicks and follows
the pointer, every click leaves a ripple, and the camera can sit in the corner as a round bubble. The
raw files stay next to the result.

### Sound

The microphone is opened only for a recording, starting with the countdown. If the system input is a
pair of Bluetooth headphones the app records from the Mac's own microphone instead, because opening a
Bluetooth microphone drops the headphones into low quality "call" sound.

## Updates

On launch the app asks GitHub for the latest release of this repository. If it is newer, a bar appears
at the bottom of the panel with an Update button: the app downloads `demosufler.zip` from the release,
checks its signature, replaces itself and restarts.

The app is signed locally (there is no paid Apple developer account), so every build has its own
signature. After an update macOS asks for camera and microphone again, and screen recording has to be
switched on once more. The panel shows what to press.

## Building

Only the Command Line Tools are needed (`xcode-select --install`), not Xcode.

```bash
./build.sh
```

builds `build/demosufler.app`. To publish an update:

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
| `landing/` | the landing page, one static file plus the video |
