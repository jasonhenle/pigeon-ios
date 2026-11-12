# Pigeon Remote (iOS companion app)

Controls Pigeon Clock and Pigeon Marquee devices over the Control API
(`../PigeonOS_0.12_Development/docs/control_api_v1.md`). SwiftUI, iOS 17+. Runs on iPhone and iPad.

    brew install xcodegen
    cd PigeonApp && xcodegen generate && open Pigeon.xcodeproj

The project file is generated from `project.yml`; don't edit `Pigeon.xcodeproj` by hand.

Try it against a Mac: start PigeonOS with `PIGEON_CONTROL_API=1`, read the code from
Settings > Pigeon (or `pigeon.control_api.pairing_code()`), then Devices > + in the app.

Implemented: discovery (Bonjour), claim with the on-screen code, a device list that shows what each
Pigeon is playing (the title's logo over its backdrop, or the song over its album art), live search and
pin/clear via `/search/*`, SSE updates, and one page per Pigeon, in this order: Clock Settings (hours,
face, temperature, zip and time zone), Playing Now with the same artwork, Display and Theme (brightness
and the theme color), Visualizer (each one previewed, playing, in the theme color), Sports via `/sports*`,
and System (name, rooms, Now Playing History, status, update, factory reset, restart, remove).

The app wears the selected Pigeon's theme color (`ThemeStore`). Removing a title from Now Playing History
(`/history`) also purges it from Pigeon Report. The visualizer previews are sprite sheets in
`Pigeon/Resources/VizPreviews`, drawn by the device's own renderer: rebuild them with
`pigeonSystem/.venv/bin/python -m pigeon.tools_build_viz_previews` when a visualizer's look changes.
Not yet: Wi-Fi.
