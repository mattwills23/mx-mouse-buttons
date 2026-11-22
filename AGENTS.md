# MX Mouse Buttons

## Scope and configuration

- This is a Swift 6 macOS helper for an MX Master connected through a Logitech Unifying receiver. It uses IOKit for the receiver, Core Graphics for shortcuts, and Service Management for login registration.
- Follow the receiver matching, HID++ button diversion, and click/hold handling in `MXMouseButtons.swift`. Keep the remapping scoped to the detected mouse and restore diverted controls when the helper stops. Use public macOS APIs and keep the app free of runtime dependencies.
- `ButtonBindings.swift` defines `BACK`, `FORWARD`, and the optional paired `THUMB_CLICK` and `THUMB_HOLD` shortcuts. The app reads the user configuration once at startup and falls back to signed bundled defaults if it cannot load it. Keep individual bindings, absolute paths, hardware identifiers unique to a device, and captures out of Git. Track only portable defaults and examples.

## Build, install, and verify

- For a personal remap, edit `~/.config/mx-mouse-buttons/.env` and preserve the other bindings. Use the installed executable with `--validate-config /path/to/.env` to check the edit. Stop the helper gracefully and reopen it to load the file. A mapping edit requires only a restart.
- For an app update, build to a staging path with `./build.sh "/tmp/mx-build/MX Mouse Buttons.app"`. The build validates the default configuration. Verify the signed app before replacing the installed copy.
- For an upgrade, stop the running helper gracefully so it can release the mouse controls. Replace the installed bundle in Applications and avoid leaving a second copy registered. Keep the bundle identifier stable and preserve login registration.
- After an ad hoc signed rebuild, the user may need to remove the old entry from macOS Accessibility permissions, then add the rebuilt app from Applications. The panel may be labeled **Device Control and Data Access**. Toggling the current entry can leave the old signature authorized. Reopen the helper after approval and check `--status`, the receiver logs, and the actual buttons on the device when possible.
- The Finder icon is `AppIcon.icns`, copied into the bundle before signing. Keep it in sync with `CFBundleIconFile` and verify that Finder displays the icon for the installed app.

## Documentation

Update the README and applicable agent instructions whenever behavior, configuration, build steps, installation, permissions, or verification change. Add the new information users or agents need and remove any instructions or descriptions that no longer apply.
