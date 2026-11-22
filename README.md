# MX Mouse Buttons

Remap MX Master buttons on macOS without Logitech software.

## Defaults

Back and Forward switch Spaces by default.

## Install

1. Use macOS 14 or later, Swift 6 via Xcode or Command Line Tools, and a Logitech Unifying receiver.
2. Run `./build.sh` to install in Applications.
3. Allow **MX Mouse Buttons** under **System Settings → Privacy & Security → Accessibility** (also called **Device Control and Data Access**). Open it from Applications to start it and register it at login.

## Update a mapping

1. Edit `~/.config/mx-mouse-buttons/.env`, using [`.env.example`](.env.example) as a template.
2. Quit **MX Mouse Buttons** in Activity Monitor and reopen it. It reads the file once at startup and uses the bundled defaults if the file is missing or invalid.

## Configurable

- `BACK` and `FORWARD` set keyboard shortcuts.
- Set both `THUMB_CLICK` and `THUMB_HOLD` to remap the thumb-rest button. Click fires on release and hold fires once after 450 ms. Without bindings, a click switches apps and holding keeps the Command–Tab switcher open on the tested Unifying setup.
- Use shortcuts such as `cmd+space` or `ctrl+left`. Modifiers are `cmd`, `ctrl`, `opt`, and `shift`.

## Unsupported

- Bluetooth and Logi Bolt connections, mouse movement gestures, and app-specific mappings.
- Left and right clicks keep their standard behavior. The thumb wheel scrolls horizontally. The top wheel scrolls vertically and middle-clicks.
- The wheel mode button toggles ratchet and free-spin. Easy-Switch cycles paired device channels.
