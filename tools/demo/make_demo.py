#!/usr/bin/env python3
"""Builds the product video of demosufler from scratch.

    python3 tools/demo/make_demo.py <work folder> [--voice-dir <folder with 01.mp3 … 08.mp3>]

Steps:
  1. Narration. With --voice-dir the ready clips are used (for example made in ElevenLabs from
     tools/demo/narration.txt). Without it the Mac's own `say` voice reads the lines, which is
     good enough to time the scenes.
  2. Timeline. Every scene is as long as its narration line, so picture and voice stay in step.
  3. Capture. build/demosufler-dev plays the timeline by itself on a clean backdrop, hidden
     behind the desktop picture, and records only its own windows.
  4. Render. The same renderer as the app's Launch mode turns the capture into the final video.

Needs: ./tools/dev.sh run once (build/demosufler-dev). Standard library only.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEV = os.path.join(ROOT, "build", "demosufler-dev")

SCRIPT = "\n".join([
    "# Launch day",
    "Hi. This is the script I am reading right now.",
    "I wrote it this morning, pasted it in, and pressed record.",
    "It scrolls right here, under the camera, so I never have to look away.",
    "[SMILE]",
    "When I slow down, I slow the text down. When I pick up the pace, it keeps up with me.",
    "I can see how long the whole thing takes before I even start.",
    "No second take because I lost my place. No eyes drifting to the side.",
    "[SHOW THE SCREEN]",
    "And while I talk, I can show my screen, my slides, or the product itself.",
    "The prompter stays on top of everything, and nobody watching ever sees it.",
    "[PAUSE]",
    "When I press stop, the video is already cut, zoomed and framed.",
    "That is the whole trick. Write it down, read it once, and post it.",
    "Thanks for watching.",
])

# One entry per scene: narration line, caption, sub-caption, shortest length in seconds,
# and the actions with times counted from the start of the scene.
SCENES = [
    {
        "say": "This is demosufler. A teleprompter that lives right under your Mac's camera, "
               "so you read your script while looking straight into the lens.",
        "title": "Read your script. Look at the lens.",
        "sub": "A teleprompter that lives under your Mac's camera",
        "card": 1,
        "min": 5.0,
        "do": [
            (0.0, {"op": "act", "target": "play"}),
            (0.9, {"op": "zoom", "x": 0.5, "y": 0.2, "scale": 1.36}),
            (1.0, {"op": "move", "target": "text", "x": 0.55, "y": 0.6, "dur": 1.3}),
        ],
    },
    {
        "say": "Set your own pace, and see how long the script will take. "
               "Fade the panel when you need to see what is behind it.",
        "title": "Your pace",
        "sub": "Speed, text size and transparency",
        "min": 6.4,
        "do": [
            (0.0, {"op": "zoom", "target": "size", "scale": 2.3}),
            (0.3, {"op": "grab", "target": "speed", "dur": 0.55}),
            (0.95, {"op": "ramp", "target": "speed", "value": 64, "dur": 1.0}),
            (2.15, {"op": "ramp", "target": "speed", "value": 26, "dur": 0.8}),
            (3.2, {"op": "grab", "target": "transparency", "dur": 0.5}),
            (3.8, {"op": "ramp", "target": "transparency", "value": 0.7, "dur": 1.0}),
            (5.3, {"op": "ramp", "target": "transparency", "value": 0.0, "dur": 0.7}),
        ],
    },
    {
        "say": "Record your camera, your screen, or both at once, each into its own file.",
        "title": "Camera, screen, or both",
        "sub": "Two files in parallel, with your microphone in each",
        "min": 4.6,
        "do": [
            (0.0, {"op": "zoom", "target": "mode.both", "y": -1.6, "scale": 2.3}),
            (0.4, {"op": "move", "target": "mode.both", "dur": 0.55}),
            (1.05, {"op": "click", "target": "mode.both"}),
            (1.7, {"op": "move", "target": "mode.screen", "dur": 0.4}),
            (2.2, {"op": "click", "target": "mode.screen"}),
            (3.0, {"op": "move", "target": "mode.camera", "dur": 0.5}),
            (3.6, {"op": "click", "target": "mode.camera"}),
        ],
    },
    {
        "say": "The prompter floats above every app, and it never shows up in your recording.",
        "title": "Always on top. Never in the video.",
        "sub": "Over full screen apps, on every desktop, hidden from screen capture",
        "min": 4.6,
        "do": [
            (0.0, {"op": "zoom", "x": 0.5, "y": 0.34, "scale": 1.3}),
            (0.6, {"op": "move", "target": "mock.chart", "dur": 1.2}),
        ],
    },
    {
        "say": "Press record. Three, two, one, and you are live.",
        "title": "One button",
        "sub": "A three second countdown, then the text starts from the top",
        "min": 5.2,
        "do": [
            (0.0, {"op": "zoom", "x": 0.56, "y": 0.2, "scale": 1.5}),
            (0.2, {"op": "move", "target": "record", "dur": 0.7}),
            (1.0, {"op": "click"}),
            (1.0, {"op": "act", "target": "reset"}),
            (1.0, {"op": "phase", "text": "countdown3"}),
            (1.65, {"op": "phase", "text": "countdown2"}),
            (2.3, {"op": "phase", "text": "countdown1"}),
            (2.95, {"op": "phase", "text": "recording"}),
            (2.95, {"op": "live", "value": 1}),
            (2.95, {"op": "act", "target": "play"}),
            (3.95, {"op": "elapsed", "value": 1}),
            (4.95, {"op": "elapsed", "value": 2}),
        ],
    },
    {
        "say": "Launch mode goes one step further. When you press stop, it builds a finished video for you. "
               "It zooms in on every click and frames your screen on a clean background. "
               "This video was made with it.",
        "title": "Launch mode",
        "sub": "Zooms on your clicks. Clean background. Ready to post.",
        "min": 9.5,
        "do": [
            (0.0, {"op": "elapsed", "value": 3}),
            (0.3, {"op": "click"}),
            (0.3, {"op": "phase", "text": "idle"}),
            (0.3, {"op": "live", "value": 0}),
            (0.5, {"op": "zoom", "target": "mode.screen", "y": -1.6, "scale": 2.1}),
            (0.8, {"op": "move", "target": "mode.launch", "dur": 0.7}),
            (1.6, {"op": "click", "target": "mode.launch"}),
            (2.6, {"op": "zoom", "scale": 1.9}),
            (2.7, {"op": "move", "target": "mock.tab1", "dur": 0.9}),
            (3.7, {"op": "click", "target": "mock.tab1"}),
            (4.9, {"op": "move", "target": "mock.tab2", "dur": 0.45}),
            (5.5, {"op": "click", "target": "mock.tab2"}),
            (6.6, {"op": "move", "target": "mock.chart", "x": 0.8, "y": 0.4, "dur": 0.8}),
            (7.6, {"op": "click"}),
            (8.8, {"op": "unzoom"}),
        ],
    },
    {
        "say": "It is free and open source, it speaks English and Russian, and it updates itself in one click.",
        "title": "Free and open source",
        "sub": "English and Russian. Updates in one click.",
        "min": 6.2,
        "do": [
            (0.0, {"op": "zoom", "x": 0.5, "y": 0.2, "scale": 1.36}),
            (0.3, {"op": "move", "target": "lang.ru", "dur": 0.7}),
            (1.1, {"op": "click", "target": "lang.ru"}),
            (2.3, {"op": "move", "target": "lang.en", "dur": 0.3}),
            (2.7, {"op": "click", "target": "lang.en"}),
            (3.1, {"op": "update", "text": "1.2.0"}),
            (3.5, {"op": "move", "target": "update", "dur": 0.8}),
            (4.5, {"op": "click", "target": "update"}),
        ],
    },
    {
        "say": "demosufler. Free for your Mac.",
        "title": "demosufler",
        "sub": "Free for Mac. macOS 15 or newer.",
        "min": 3.4,
        "do": [
            (0.0, {"op": "unzoom"}),
            (0.0, {"op": "update", "text": ""}),
            (0.2, {"op": "move", "x": 0.86, "y": 0.9, "dur": 1.2}),
        ],
    },
]

LEAD_IN = 0.7     # silence before the first line
GAP = 0.45        # pause between a line and the next scene


def duration(path):
    out = subprocess.run([DEV, "--probe", path], capture_output=True, text=True, check=True).stdout
    return float(out.split()[1].rstrip("s"))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    work = os.path.abspath(sys.argv[1])
    voice_dir = None
    if "--voice-dir" in sys.argv:
        voice_dir = os.path.abspath(sys.argv[sys.argv.index("--voice-dir") + 1])
    os.makedirs(work, exist_ok=True)

    # 1. Narration clips and their lengths.
    clips = []
    for index, scene in enumerate(SCENES, start=1):
        ready = None
        if voice_dir:
            for ext in ("mp3", "m4a", "wav", "aiff"):
                candidate = os.path.join(voice_dir, f"{index:02d}.{ext}")
                if os.path.exists(candidate):
                    ready = candidate
                    break
            if ready is None:
                sys.exit(f"no clip {index:02d} in {voice_dir}")
        else:
            ready = os.path.join(work, f"say_{index:02d}.aiff")
            subprocess.run(["say", "-v", "Daniel", "-r", "178", "-o", ready, scene["say"]], check=True)
        clips.append((ready, duration(ready)))

    # 2. Timeline: every scene lasts as long as its line (or its actions, if those take longer).
    timeline = [
        {"t": -1, "op": "script", "text": SCRIPT},
        {"t": -1, "op": "set", "target": "speed", "value": 24},
        {"t": -1, "op": "set", "target": "size", "value": 30},
    ]
    voice = []
    start = LEAD_IN
    for scene, (clip, length) in zip(SCENES, clips):
        caption = {"t": start - 0.25 if start > LEAD_IN else 0, "op": "caption",
                   "text": scene["title"], "sub": scene["sub"]}
        if "card" in scene:
            caption["value"] = scene["card"]
        timeline.append(caption)
        for offset, action in scene["do"]:
            timeline.append(dict(action, t=round(start + offset, 3)))
        voice.append({"file": clip, "at": round(start, 3)})
        start += max(scene["min"], length + GAP)
    total = start + 0.6
    timeline.append({"t": round(total, 3), "op": "end"})

    with open(os.path.join(work, "timeline.json"), "w") as f:
        json.dump(timeline, f, indent=1)
    with open(os.path.join(work, "voice.json"), "w") as f:
        json.dump(voice, f, indent=1)
    with open(os.path.join(ROOT, "tools", "demo", "narration.txt"), "w") as f:
        f.write("\n".join(f"{i:02d}. {s['say']}" for i, s in enumerate(SCENES, start=1)) + "\n")
    print(f"timeline: {len(timeline)} actions, {total:.1f}s")

    if "--timeline-only" in sys.argv:
        return

    # 3. Capture.
    version = open(os.path.join(ROOT, "VERSION")).read().strip()
    env = dict(os.environ, DEMOSUFLER_DEMO=os.path.join(work, "timeline.json"),
               DEMOSUFLER_DEMO_OUT=work, DEMOSUFLER_VERSION=version)
    screen = os.path.join(work, "demo_screen.mov")
    for attempt in range(1, 6):
        subprocess.run([DEV], env=env, check=True)
        # The windows are hidden behind the desktop picture. If the person at the Mac switches
        # desktops during the capture, macOS stops drawing them for a moment and the recording
        # gets black frames. Check for that and simply film again.
        check = subprocess.run([DEV, "--check-dark", screen], capture_output=True, text=True)
        print(f"capture {attempt}: {check.stdout.strip()}")
        if check.returncode == 0:
            break
    else:
        sys.exit("every capture had black frames")

    # 4. Render: a silent cut and a narrated cut.
    track = os.path.join(work, "demo_track.json")
    common = [DEV, "--render", screen, "--track", track, "--size", "1920x1080", "--fps", "30", "--bitrate", "3000000"]
    subprocess.run(common + ["--out", os.path.join(work, "demo_silent.mp4")], check=True)
    subprocess.run(common + ["--voice", os.path.join(work, "voice.json"),
                             "--out", os.path.join(work, "demo_voiced.mp4")], check=True)
    for t, name in ((total * 0.42, "poster.png"),):
        subprocess.run([DEV, "--frame", os.path.join(work, "demo_silent.mp4"), f"{t:.2f}",
                        os.path.join(work, name)], check=True)
    print("done:", work)


if __name__ == "__main__":
    main()
