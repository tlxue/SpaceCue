# SpaceCue

Small personal macOS widget for seeing and jumping between Spaces.

## Requirements

- macOS 14 or newer.
- Xcode Command Line Tools with `swiftc`, `xcrun`, and `codesign`.
- Accessibility permission for keyboard fallback switching.

## Build and Run

From the project folder:

```sh
./install.sh
open "$HOME/Applications/SpaceCue.app"
```

If it is already running and gets into a bad state:

```sh
killall SpaceCue
open "$HOME/Applications/SpaceCue.app"
```

For local build-only testing:

```sh
./build.sh
open build/SpaceCue.app
```

For Accessibility permission stability, install the runnable app outside this Codex workspace:

```sh
./install.sh
open -n -F "$HOME/Applications/SpaceCue.app"
```

`install.sh` signs the app with a stable local code-signing identity by default. The generated signing material lives outside the repository under `$HOME/Library/Application Support/SpaceCue/signing`. If Accessibility keeps prompting after a rebuild, reset the old ad-hoc grant once, reopen the app, and grant permission again:

```sh
tccutil reset Accessibility com.tianlu.SpaceCue
open -n -F "$HOME/Applications/SpaceCue.app"
```

## Controls

- `Command + 1...9`: switch to the matching Space.
- Click a pill: switch to that Space.
- Right-click a pill: rename or clear its label.
- Drag the background of the floating strip to reposition it.
- Use the `Spaces` menu bar item to show the widget, reset its position, refresh, rename the current Space, request permissions, or quit.

## Notes

- macOS does not expose Spaces through a stable public API. This app uses private CoreGraphics APIs for listing and switching Spaces, so it is for personal use and not suitable for the Mac App Store.
- Labels are inferred from the current Space as you use it. If macOS hides window titles, use the menu bar item to request window-name permission, or manually rename Spaces.
- Full-screen Spaces such as Dia use macOS keyboard Space transitions instead of the private switch API. Grant Accessibility permission to `$HOME/Applications/SpaceCue.app` so this path can post `Control + Left/Right`.
- If the private switch API fails, SpaceCue falls back to sending macOS keyboard shortcuts. Enable Mission Control's desktop shortcuts in System Settings and grant Accessibility permission.
- Local code-signing material is generated outside the repository by default. The repo-local `signing/` directory is ignored by git and should not be committed.

## License

MIT. See [LICENSE](LICENSE).
