# DockBar

DockBar is a taskbar for working across more than one display. The native Dock is a single strip for the whole Mac, so a click often opens or focuses a window on another screen and that window is easy to lose. DockBar puts a bar on every display and keeps each display's windows with that bar.

Clicking an app opens or focuses its window on the display you clicked. Hover previews show the windows on that display. Pinned apps can appear on every screen, so the same apps are ready wherever you are working. The behavior is the Windows taskbar. The look stays Mac: Liquid Glass, either a full-width bar or a floating capsule.

DockBar hides the Dock while it runs and puts your previous Dock setting back when you quit. A menu-bar icon opens settings. DockBar itself does not appear in the Dock.

## Requirements

- macOS 26 or later
- Swift 6.2 command-line tools

## Install

```bash
scripts/build-app.sh
open ~/Applications/DockBar.app
```

The build script compiles a release binary, signs it with a local **DockBar Development** certificate, and copies `DockBar.app` to `~/Applications`. Reusing that certificate keeps the Accessibility and Screen Recording grants you already gave the app.

The first launch asks for the permissions below. Grant Accessibility if you want clicks to focus, minimize, and close windows.

## Use the bar

The DockBar icon in the menu bar opens **Settings…**, **Permissions…**, and **Quit and Restore Dock**. Right-click an empty part of the bar for the same preferences and quit commands.

| Action | Result |
| --- | --- |
| Click a pinned app that is not running | Launches it |
| Click an app with one window | Focuses that window, or minimizes it if it is already focused |
| Click an app with several windows | Shows previews. Click the icon again to cycle through them |
| Point at an app | Shows a preview of each window on that display. Click a preview to focus it, or close it from the preview |
| Option-click or middle-click an app | Opens a new window |
| Right-click an app | Menu for its windows, New Window, Pin or Unpin, Show in Finder, and Quit |
| Drag an app from Finder onto the bar | Pins it where the pointer is. A gap and a plus mark the landing spot |
| Click and drag a pinned icon | Reorders it. Finder stays first |
| Drag a pinned icon to the Trash | Unpins it. The Trash magnifies while the drop is accepted |
| Drop files on the Trash | Moves them to the Trash |
| Click the Trash | Opens the Trash |
| Right-click the Trash | Empty Trash |

Windows open on the display where you clicked the button. Turn that off in Settings if you want macOS to place them.

## Settings

Open **Settings…** from the menu-bar icon.

- **Icons** — center the icons, or line them up on the left
- **Bar** — full width, or a floating capsule
- **Bar height** and **Icon size**
- **Show pinned apps on every screen**
- **Show Finder** and **Show Trash**
- **Open on the clicked display**
- **Launch DockBar at login**

Quitting from the menu, or **Quit and Restore the macOS Dock** in Settings, restores the Dock autohide setting DockBar found when it launched.

If the Dock stays hidden after DockBar stops, run:

```bash
scripts/restore-dock.sh
```

## Permissions

| Permission | Why |
| --- | --- |
| Accessibility | Focus, minimize, and close windows, and keep maximized windows clear of the bar |
| Screen Recording | Draw window previews |
| Finder Automation | Show whether the Trash is full, and empty it |

## Develop

```bash
scripts/check-coverage.sh
```

That runs the test suite and fails if line coverage of `Sources/DockBar` is under 70%. Run it before every commit and push.

DockBar is a Swift package. The app target is `Sources/DockBar`. Tests live in `Tests/DockBarTests` and use Swift Testing.

## License

DockBar is released under the [MIT license](LICENSE).
