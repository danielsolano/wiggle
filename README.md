# Wiggle

**English** · [Español](README.es.md)

A tiny menu bar (macOS) and system tray (Windows) app that nudges the mouse cursor by a couple of pixels when you have been idle, so your computer and apps like Teams or Slack do not mark you as away.

## Build it yourself, install nothing

Wiggle is meant to be **built from this repository on your own machine**. There is no installer, no download page and no package to fetch:

- **You only need the repo.** Clone it (or download it as a ZIP) and run one build script.
- **Windows needs nothing installed.** The build uses the C# compiler that is already part of Windows 10 and 11.
- **macOS needs only Apple's Command Line Tools**, which many laptops already have.
- **No admin rights.** The result is a portable app that runs from any folder you can write to.
- **No "downloaded from the internet" warnings.** An app compiled locally is not quarantined, so Gatekeeper and SmartScreen have nothing to flag.

The source is two small files, so you can read everything it does before you build it.

## Windows

1. Open the `Windows` folder.
2. Double-click `build.cmd`.
3. Run `Windows\dist\Wiggle.exe`.

A **W** icon appears next to the clock (it may be hidden under the `^` overflow arrow). Click it to open the menu. The icon is green while Wiggle is active and gray while it is paused.

- **Portable:** `Wiggle.exe` is a single file of about 64 KB. Copy it anywhere.
- **Settings** are saved to `wiggle.ini` next to the `.exe`. If that folder is read-only, settings just do not persist.
- **No registry changes, no services, no autostart.** To launch it at sign-in, put a shortcut in the folder that opens with `Win+R` → `shell:startup`.

## macOS

1. Check that the Command Line Tools are present: `xcode-select -p` prints a path if they are. If not, run `xcode-select --install`.
2. Build:

   ```bash
   cd macOS
   ./build.sh
   ```

3. Run it in place with `open dist/Wiggle.app`.

A **W** icon appears in the menu bar. It is dimmed while Wiggle is paused and turns into a warning sign while the Accessibility permission is missing.

`./install.sh` is optional: it builds and then copies the app to `/Applications`, or to `~/Applications` when you cannot write to `/Applications`. Use it if you want "Open at login", which needs the app to stay in a fixed location.

`build.sh` also produces `dist/Wiggle-<version>.dmg`. A DMG passed to another Mac is treated as a download and Gatekeeper will block it, so the reliable way to share Wiggle is to share the repo and let each person build it.

### Accessibility permission

macOS only lets an app move the cursor if it has the Accessibility permission.

1. The first time you start Wiggle, macOS shows a prompt.
2. Open System Settings → Privacy & Security → Accessibility.
3. Turn on **Wiggle**.

Until you do, the menu shows "⚠ Needs Accessibility permission" and the cursor is not moved. Wiggle picks up the permission as soon as you grant it.

The app is signed ad-hoc, so macOS may ask again after you rebuild. If the switch is already on and it still does not work, remove Wiggle from the list with "−" and add it back.

## How it behaves

Both platforms follow the same rules:

| Setting | Options | Default |
|---|---|---|
| Interval | 10 s, 30 s, 1 min, 2 min, 5 min | 30 s |
| Movement distance | 1, 2, 5, 10, 25 px | 2 px |
| Move only when I am idle | on / off | on |
| Keep display awake | on / off | on |
| Open at login (macOS 13+ only) | on / off | off |

- Wiggle checks every 2 seconds. With **Move only when I am idle** on, it nudges the cursor once you have been idle for the chosen interval, and never while you are working. With it off, it nudges every interval regardless.
- A nudge moves the cursor sideways by the chosen distance and puts it back exactly where it was.
- **Keep display awake** stops the display from sleeping while Wiggle is active.
- Wiggle remembers whether it was active and restores that state the next time it starts.
- The menu is in Spanish when the system language is Spanish, and in English otherwise.

Chat apps mark you as away after a fixed idle time (commonly 5 minutes), so pick an interval well below that.

## Updating

- **If you built from the repo:** pull the latest changes and run the build script again.
- **If you downloaded a release:** choose **Check for Updates…** in the menu. When a newer version exists, Wiggle offers to open the download page; it never downloads or installs anything by itself.

Wiggle never connects to the internet on its own. The update check is its only network request, it goes to `api.github.com`, and it happens only when you click that menu item.

To publish a version, bump it in `macOS/Resources/Info.plist` and in the `AssemblyVersion` lines of `Windows/Program.cs`, build both apps, and create a GitHub release tagged `vX.Y.Z` with the DMG and the `.exe` attached. The update check compares against the latest release tag.

## Things to know

- **Your screen will not lock by itself** while Wiggle is active. Lock it manually when you walk away (`Win+L`, or `Ctrl+Cmd+Q` on a Mac).
- **It is not invisible.** The moves are synthetic input that monitoring software can tell apart from a real mouse, and the app is unsigned. Some managed machines also block unsigned programs from running at all.
- **You are responsible for how you use it.** Check what your organization's policies allow.

## Repository layout

```
assets/                    # logo sources and the script that regenerates the icons
macOS/
├── Sources/main.swift     # all logic and UI
├── Resources/             # Info.plist and the app icon
├── build.sh               # builds, signs and creates the DMG
└── install.sh             # optional: build and copy to Applications
Windows/
├── Program.cs             # all logic and UI
├── Resources/Wiggle.ico   # icon embedded in the .exe
├── build.cmd              # builds on Windows with the built-in compiler
├── build.sh               # cross-builds from macOS/Linux (needs the .NET SDK)
└── Wiggle.csproj          # project file used only by build.sh
```

The app icons are committed, so building never requires image tools. After changing the logo in `assets/`, run `python3 assets/make_icons.py` on a Mac to regenerate them. The menu bar and tray icon is drawn in code from the outline in `assets/wiggle-menu.svg`.

The Windows source sticks to C# 5 so the compiler bundled with Windows can build it. `Wiggle.csproj` enforces this, so a build through `build.sh` fails if newer syntax slips in.
