# Pigeon (iOS companion app)

Controls Pigeon Clock and Pigeon Marquee devices over the Control API
(`docs/control_api_v1.md` in the PigeonOS repo, `jasonhenle/pigeon_OS_0.12.x_JEH`). SwiftUI, iOS 17+.
Search is the first tab.

## Build

    brew install xcodegen
    xcodegen generate
    open Pigeon.xcodeproj

Run these from the repo root. The project file is generated from `project.yml`; change settings and
sources there rather than editing `Pigeon.xcodeproj` by hand. Run tests with the `Pigeon` scheme
(`PigeonTests`).

## Turn on the Control API on the Pigeon

The Control API is **off by default** on the device, so the app finds nothing until it's enabled.
Either:

- start PigeonOS with `PIGEON_CONTROL_API=1`, or
- set `"control_api": true` in `~/.pigeon_0_6/state.json` and restart.

The API listens on port 8780 and advertises itself over Bonjour (`_pigeon._tcp`; needs the optional
`zeroconf` package on the device). The phone must be on the same network, and Local Network access
must be allowed for Pigeon in iOS Settings. If discovery finds nothing, Add device shows these steps
and lets you connect by address.

## Pairing

Pick a device (or enter its address) and the device shows a 6-digit code full screen; type it in the
app. Seeing the screen is the proof of presence, so this works on an already-claimed device too. That
is the way to add a second phone or re-pair one that lost its pairing: use Add device again and enter
the on-screen code. Pairing with the same phone replaces its old entry. Removing a device in the app
also unpairs this phone on the device.

The app has no invite or controller-management screen; the API's `/controllers/invite` and
`/controllers` endpoints exist but aren't used here.

## Features

- Discovery (Bonjour) and adding by address, pairing with the on-screen code
- Device list, rename, remove, live status over SSE
- Search: live suggestions, pin and clear the current search
- Now-playing corrections: edit fields, preview, pick a TMDb match, clear the correction
- Rooms: view, switch, rename
- Pigeon-page settings from the device
- Display brightness

Not yet: Wi-Fi setup, clock settings, player and receiver pairing, controller invites, and any device
feature the device doesn't report in `/capabilities`.
