# Showing an activity from another app

Any Mac app can put an activity in the DynamicMenu pill by posting a distributed
notification. No framework or entitlement is needed, and it works from sandboxed apps.

## Notifications

| Name | Meaning |
|---|---|
| `DynamicMenu.Activity.Update` | Start an activity, or replace its content |
| `DynamicMenu.Activity.End` | Remove it |

The notification's `object` is a JSON string. Do not use `userInfo`: macOS removes it
from notifications posted by sandboxed apps.

Post with `deliverImmediately: true`.

## Payload

| Field | Type | Required | Shown as |
|---|---|---|---|
| `id` | string | yes | Not shown. Updates with the same `id` replace the previous content. |
| `app` | string | no | Name of your app, shown in DynamicMenu's Settings so the user can mark it important. Falls back to `id`. |
| `bundleID` | string | no | Your app's bundle identifier. The arrow in the expanded pill opens it. |
| `openURL` | string | no | A link that opens your app at the right place (a deep link). Used for the arrow instead of `bundleID`. |
| `title` | string | no | Title in the expanded pill |
| `symbol` | string | no | SF Symbol name, left slot. Unknown names fall back to a generic icon. |
| `value` | string | no | Short text in the right slot, e.g. `"3 min"` |
| `progress` | number 0–1 | no | Bar in the expanded pill; a percentage in the right slot if there is no `value` |
| `endDate` | number, seconds since 1970 | no | Live countdown in the right slot, in place of `value` |
| `startDate` | number, seconds since 1970 | no | Time counting up since then in the right slot, in place of `value` (a task being timed) |
| `tint` | string `"#RRGGBB"` | no | Colour of the symbol and value |

Keep `value` to a few characters. The compact pill is small.

## Example

```swift
import Foundation

func postActivity(_ name: String, _ payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(name),
        object: String(decoding: data, as: UTF8.self),
        userInfo: nil,
        deliverImmediately: true)
}

// Start or update
postActivity("DynamicMenu.Activity.Update", [
    "id": "com.example.export",
    "title": "Exporting video",
    "symbol": "film",
    "progress": 0.42,
    "tint": "#FF9F0A",
])

// Finish
postActivity("DynamicMenu.Activity.End", ["id": "com.example.export"])
```

The expanded pill shows an arrow that opens your app. It uses `openURL` if given, else
`bundleID`, else your running app found by its `app` name. Without any of them there is
no arrow.

## Buttons

Send up to three `actions` and the expanded pill shows a labelled button for each, in a row under the title (only the arrow that opens your app is an icon). `symbol` is kept for your own use; `label` is the button's text:

```json
"actions": [
  {"id": "pause", "symbol": "pause.fill", "label": "Pause"},
  {"id": "stop",  "symbol": "stop.fill",  "label": "Stop"}
]
```

When one is pressed, DynamicMenu posts `DynamicMenu.Activity.Action` with the JSON
`{"id": "<your activity id>", "action": "<the button id>"}` in `object`. Listen for it and
act (pause the timer, cancel the export), then send an `Update` with the new state, for
example a "play.fill" button once paused. An action with a `url` opens that link instead,
which also works when your app is not running. Anyone can post this notification too, so
check what it asks before doing something destructive.

## Behaviour

- Always send `End` when the task finishes. An activity that receives no update for
  eight hours is removed automatically.
- By default an app's activities sit beside the main pill, below media, timers and calendar
  events and above the file shelf and the camera/microphone indicator. The first time an
  app sends one, it appears in DynamicMenu's Settings under Activities › Apps, where the
  user can mark it **Important**: it then takes the main pill, above Now Playing (alerts
  such as battery, volume and a finished timer still come first).
- There is no authentication: any process on the Mac can post. Do not treat what the
  pill shows as coming from a trusted source.
