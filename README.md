# DynamicMenu

### A Menu point of view.

Music, timers, meetings and files right in your menu bar.

On a Mac with a notch, it grows out of the notch. On any other display, it floats at the top of
the screen as a small black pill. Free and open source under the [MIT license](LICENSE), for
macOS 26 or later.

**[See it in motion](https://markolko-447.github.io/DynamicMenu/)**

> DynamicMenu is an independent project. It is not affiliated with or endorsed by Apple Inc.

## What it does

**Whatever is playing.** Control music, podcasts or a video in any browser tab. Skip, scrub and
save a track without leaving what you're doing.

**Multiple Activities.** Control your music, watch a timer and stay ahead of your next meeting,
all at the same time.

**Never late again.** Get a heads-up before every appointment, and join the call straight from
DynamicMenu.

**Files on their way.** Follow every download and AirDrop transfer as it happens, without
opening a window.

**A Shelf.** Drag a file toward the top of your screen, drop it in, and drag it out again
whenever you need it.

**Your AirPods.** Their battery level shows up as soon as they connect, and again when you
unlock.

**Camera and microphone.** The pill lights up whenever either one is in use.

**And the little things.** Wi-Fi, VPN and Hotspot. Volume and brightness. Charging, low battery
and Low Power Mode. Caps Lock and the other small moments you would otherwise miss.

**Third party apps, too.** Give your app its own place on the pill, with buttons of its own.
It takes a few lines of code (see below).

**Then it steps aside.** Nothing going on? It leaves your menu bar alone.

## Pill or notch

DynamicMenu chooses for you. A Mac with a notch gets the notch version, which shows one
activity at a time. Every other display, including external monitors and Macs without a notch,
gets a floating pill, and the second and third activities sit beside it as bubbles.

## What comes first

When several things are going on, the most important one takes the pill. The order is a
finished timer, battery, small alerts, third party apps you marked as important, Now Playing,
downloads, a running timer, the calendar, other third party apps, the shelf, and last the
camera and microphone.

## Make it yours

In Settings you can switch each kind of activity on or off, choose Solid, Gradient or Glass for
each display (Glass is for displays without a notch), and mark which third party apps are
important. Apps appear in that list the first time they send an activity.

## Privacy

Everything stays on your Mac. DynamicMenu reads your calendar, what is playing, and whether the
camera and microphone are in use, only to show them on the pill. It doesn't send your data
anywhere, and it has no analytics.

## Known limits

- macOS still shows its own volume and brightness overlay. The pill shows the level as well, but
  there is no safe, supported way to hide the system's.
- macOS doesn't say which app is using the camera, so only the microphone names an app.
- Reading what is playing uses a private system framework (see below), so DynamicMenu can't go
  on the Mac App Store, and a macOS update can break it.
- The notch version shows one activity at a time, by design.

## Build

You need Xcode with the macOS 26 SDK.

```sh
git clone https://github.com/markolko-447/DynamicMenu.git
cd DynamicMenu
open DynamicMenu.xcodeproj
```

Choose your own signing team in Signing & Capabilities, then run. The app lives in the menu
bar and has no Dock icon.

DynamicMenu asks for access when it first needs it. Calendars for events, folders for the shelf
and downloads, and Automation for controlling Music. Settings lists them under Permissions.
Camera and microphone status needs no permission, because it only reads whether they are on.

### Now Playing helper

Since macOS 15.4 the system's media information only answers Apple-signed processes, so the app
reads it through a small helper library (`DynamicMenu/Resources/NowPlayingBridge.bin`) that it
loads into `/usr/bin/perl`. It uses a private system framework, which is why the limits above
apply.

## Show your own app's activity

Any Mac app can put an activity on the pill: a task being timed, an export, a game score. There
is nothing to install or link against. Your app posts a **distributed notification** whose
`object` is a JSON string, and DynamicMenu shows it. It works from sandboxed apps, and
no entitlement is needed.

| Notification | Meaning |
|---|---|
| `DynamicMenu.Activity.Update` | Start an activity, or replace its content |
| `DynamicMenu.Activity.End` | Remove it |
| `DynamicMenu.Activity.Action` | Sent **to your app** when the user presses one of your buttons |

```swift
import Foundation

func post(_ name: String, _ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(name),
        object: String(decoding: data, as: UTF8.self),   // the JSON goes in `object`, not `userInfo`
        userInfo: nil,
        deliverImmediately: true)                        // DynamicMenu is never frontmost
}

// Start, or update the same activity (same id replaces it)
post("DynamicMenu.Activity.Update", [
    "id": "com.example.timer",            // required, yours to choose
    "app": "Example",                     // shown in Settings so the user can mark it important
    "title": "Quarterly report",
    "symbol": "timer",                    // an SF Symbol name
    "startDate": Date().timeIntervalSince1970,   // counts up; use "endDate" to count down
    "tint": "#34C759",
    "bundleID": "com.example.app",        // the arrow opens your app (or give "openURL")
    "actions": [                          // up to three buttons, shown as words
        ["id": "pause", "symbol": "pause.fill", "label": "Pause"],
        ["id": "stop",  "symbol": "stop.fill",  "label": "Stop"],
    ],
])

// Listen for the buttons
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("DynamicMenu.Activity.Action"), object: nil, queue: .main
) { note in
    guard let json = note.object as? String,
          let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
          message["id"] == "com.example.timer" else { return }
    // message["action"] is "pause" or "stop": do it, then post an Update with the new state.
}

// Finish. Always send this when the task is over.
post("DynamicMenu.Activity.End", ["id": "com.example.timer"])
```

**Fields** (only `id` is required): `app`, `title`, `symbol`, `value` (a few characters for the
compact view), `progress` (0 to 1), `endDate` or `startDate` (seconds since 1970), `tint`
(`"#RRGGBB"`), `bundleID`, `openURL`, `actions`.

**Good to know**
- DynamicMenu must be running. Notifications aren't queued, so post your state again when your
  app launches.
- The first time an app sends an activity, it appears in **Settings → Activities → Apps**. There
  the user can mark it **Important**: it then takes the main pill, above Now Playing. Otherwise it
  sits beside the pill. Alerts such as battery and a finished timer always come first.
- An action with a `url` opens that link instead of notifying your app, which works even when your
  app isn't running.
- There is no authentication: any process on the Mac can post, and anything can post an
  `Action` message too. Check what you are asked to do before doing something destructive.
- Activities nobody updates for eight hours are removed.

The full reference is in [Docs/ExternalActivities.md](Docs/ExternalActivities.md).

## Website

The site at **https://markolko-447.github.io/DynamicMenu/** is the `website` folder. A workflow in
`.github/workflows/pages.yml` publishes it to GitHub Pages whenever it changes on `main`. It is
plain HTML with no build step. Serve the folder with any static web server to preview it.

The pill in its videos is the app itself, recorded with a fixed clock so a calendar event always
reads the same.

The code is MIT. The two wallpapers in `website/assets` are not part of that license. One is the
author's own, and the other is a photo from [Pixabay](https://pixabay.com/) used under its license.

## Project layout

| Folder | What's in it |
|---|---|
| `DynamicMenu/Pill` | The pill itself, with its shape, its motion and the fluid bubble effect |
| `DynamicMenu/Activities` | One module for each kind of activity |
| `DynamicMenu/Screens` | Finding displays, the notch, and menu bar space |
| `DynamicMenu/Settings` | Settings and permissions |
| `Docs` | The activity API for other apps |
| `website` | The website, published with GitHub Pages |

## Contributing

Issues and pull requests are welcome. Please keep to the existing style, describe what
changed and why, and say how you checked it. Anything that moves the pill should be watched
running, not only looked at in a screenshot.

## License

[MIT](LICENSE) © 2026 markolko-447. Apple, Mac, MacBook, macOS and AirPods are trademarks of
Apple Inc.
