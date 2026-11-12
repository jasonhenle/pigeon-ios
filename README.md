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

Each Pigeon's pages wear its theme color (`ThemeStore`); the Devices list belongs to no Pigeon, so it
stays Pigeon blue with a white +, and shows each Pigeon's color as a dot by its name.

Away from a Pigeon's network the app keeps showing it: the last answers to its settings, rooms, history,
visualizer and sports reads are kept per Pigeon (`ResponseCache`, in Caches), the page says "Not
connected", and it reloads by itself once the Pigeon answers again (`Connectivity`). What is playing is
never shown from memory. System › Send Developer Feedback drafts an email to hello@thepigeonlabs.com. Removing a title from Now Playing History
(`/history`) also purges it from Pigeon Report. The visualizer previews are sprite sheets in
`Pigeon/Resources/VizPreviews`, drawn by the device's own renderer: rebuild them with
`pigeonSystem/.venv/bin/python -m pigeon.tools_build_viz_previews` when a visualizer's look changes.
Not yet: Wi-Fi.
