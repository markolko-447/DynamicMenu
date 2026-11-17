# DynamicMenu

A pill in your Mac's menu bar for what is happening right now: the song that's playing, a
timer, your next meeting, a download, the files on your shelf. On a MacBook with a notch it
grows out of the notch; on any other display it floats at the top of the screen.

Free and open source, [MIT licensed](LICENSE). Requires macOS 26 or later.

> DynamicMenu is an independent project. It is not affiliated with or endorsed by Apple Inc.

## What it shows

- **Now Playing** from any app, including video in a browser tab, with play, skip and scrub.
- **Timers** from the Clock app, and a finished timer that rings.
- **Calendar** events a few minutes before they start, with a button to join the call.
- **Downloads and AirDrop**, with progress.
- **A file shelf**: drop files on the pill to keep them close, drag them out when you need them.
- **Short alerts**: volume and brightness, Wi-Fi, VPN and Hotspot, AirPods and their battery,
  unlock, Caps Lock, Low Power Mode, charging.
- **Camera and microphone in use**, with the app using the microphone.
- **Activities from other apps**, with buttons of their own (see below).

Several activities at once: the most important takes the pill, the next two sit beside it as
bubbles. (A notch shows one at a time.) Settings let you switch each kind off, choose Solid,
Gradient or Glass for each display, and mark which of your apps count as important.

## Build

You need Xcode with the macOS 26 SDK.

```sh
git clone https://github.com/markolko-447/DynamicMenu.git
cd DynamicMenu
open DynamicMenu.xcodeproj
```

Choose your own signing team in the project's Signing & Capabilities, then run. The app
lives in the menu bar and has no Dock icon.

DynamicMenu asks for access when it first needs it: Calendars for events, folders for the
shelf and downloads, Automation for controlling Music. Settings → Permissions lists them.

### Now Playing helper

Since macOS 15.4 the system's media information only answers Apple-signed processes, so the
app reads it through a tiny library loaded into `/usr/bin/perl`
(`Helper/NowPlayingBridge.m`, built into `DynamicMenu/Resources/NowPlayingBridge.bin` by
`Helper/build.sh`). It uses a private system framework, so a build of DynamicMenu can't be
distributed through the Mac App Store, and Apple can change it at any time.

## Show your own app's activity

Any Mac app can put an activity on the pill by posting a distributed notification, with no
framework or entitlement, and add buttons that call back into the app. See
[Docs/ExternalActivities.md](Docs/ExternalActivities.md).

## Project layout

| Folder | What's in it |
|---|---|
| `DynamicMenu/Pill` | The pill itself: shape, motion, the fluid bubble effect |
| `DynamicMenu/Activities` | One module per kind of activity |
| `DynamicMenu/Screens` | Finding displays, the notch, and menu bar space |
| `DynamicMenu/Settings` | Settings and permissions |
| `DynamicMenu/Demo` | The recorder that renders the pill's real animations to video |
| `Helper` | The Now Playing helper |
| `Docs` | The activity API for other apps |

## Contributing

Issues and pull requests are welcome. Please keep to the existing style, describe what
changed and why, and say how you checked it. Anything that moves the pill should be looked
at in a recording (`--render-clips`, see `DynamicMenu/Demo/ClipRenderer.swift`), not only in
a screenshot.

## License

[MIT](LICENSE) © 2026 markolko-447. Apple, Mac, MacBook, macOS and AirPods are trademarks of
Apple Inc.
