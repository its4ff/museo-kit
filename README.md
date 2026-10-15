# MuseoKit

MuseoKit is the Swift package that talks to the museo ring. It sets the ring up with iOS's own accessory sheet, keeps the link, streams live recordings while you hold the ring, brings in the ones saved on the ring's memory, decodes them to WAV and updates the ring's firmware. Your app gets each finished recording once, one small status value for its screens, ring events, and closures for its buttons. Everything below that line (Bluetooth, the ring's protocol, sync, setup, firmware) is sealed inside the package.

## What you get

**Start it once,** at launch, in `application(_:didFinishLaunchingWithOptions:)`. Never in a view: iOS relaunches the app in the background for the ring, with no screen up.

```swift
import MuseoKit

Museo.start(name: "museo")   // what iOS's accessory sheet calls the ring
```

**Keep each recording, then say so.** Return true only once it's safe on the phone. A memory recording stays on the ring until you do and comes back with the next sync. A live recording has no copy on the ring, so the kit holds it and offers it again until you return true.

```swift
Museo.onCapture { capture, seenBefore in
    if seenBefore { return true }   // brought in before, or deleted on purpose: keep what you have
    let folder = RingBLEManager.capturesDirectory
    let wav = folder.appendingPathComponent(capture.wavFileName ?? capture.fileName)
    return library.add(wav, at: capture.startedAt, live: capture.source == .stream)   // your save; true once it's on disk
}
```

- One handler. Setting another replaces it. Recordings that finish before you set it wait in the kit and arrive as soon as you do.
- Live presses under 1 s (`Museo.shortestCapture`) are accidental. They're dropped before they reach you.
- Call `Museo.takeWaitingCaptures()` from a foreground sweep to be sure nothing is still waiting.

**Hear what the ring is doing.** Any number of listeners, on the main actor.

```swift
Museo.onEvent { event in
    switch event {
    case .liveStarted(let at):          print("listening since", at)
    case .liveEnded:                    print("sending")
    case .syncStarted(let count):       print("bringing in", count)
    case .syncProgress(let remaining):  print(remaining, "to go")
    case .syncEnded:                    print("done")
    }
}

for await event in Museo.events() { … }   // the same, as an async sequence
```

**Words while you speak.** The audio of a hold as it arrives: 16 kHz mono, about every 100 ms. Hand it to a recognizer (Apple's `SpeechAnalyzer` takes `chunk.buffer()` as is). It only decodes while a stream is open, so stop listening when nothing is on screen. Memory recordings never come through here; they arrive whole, through `onCapture`.

```swift
for await piece in Museo.liveAudio() {
    switch piece {
    case .began(let at):        print("hold began", at)
    case .samples(let chunk):   feed(chunk.buffer())   // AVAudioPCMBuffer, 16 kHz mono Int16
    case .ended:                print("hold ended")
    }
}
```

**Show the ring in a view.** `RingModel.status` is one `Equatable` value that changes only when something on screen would, never per packet.

```swift
struct RingLine: View {
    @Environment(RingModel.self) private var ring
    var body: some View {
        Text(ring.status.shortLine)   // "ring linked", "listening…", "bringing in 3"
    }
}

RootView().environment(RingModel.shared)            // the app
RingLine().environment(RingModel.preview(.syncing))  // previews and mock screens
```

- State: `link`, `battery`, `isCharging`, `isLive`, `isRecordingOnRing`, `isSyncing`, `waiting`, `freeStoragePercent`, `minutesLeft`, `isLowBattery`, `isStorageLow`.
- Ready-made copy, lowercase: `shortLine`, `headline`, `deviceLine`, `batteryLine`, `storageLine`, `accessibilityLabel`.
- Fixtures for previews: `.notSetUp`, `.joining`, `.linked`, `.linkedLow`, `.charging`, `.live`, `.syncing`, `.nearlyFull`, `.away`, `.bluetoothOff` (all in `RingStatus.fixtures`).
- The ring reports "recording" during a live hold too. Check `isLive` before `isRecordingOnRing`.

**Make the ring do something** with `RingActions`, a struct of closures, so ring screens stay previewable.

```swift
let actions = RingActions.live(openFirmware: { showFirmware = true })
actions.setUp()          // iOS's accessory sheet
actions.lookForIt()      // a ring that's set up but away
actions.syncNow()        // bring waiting recordings in
actions.refresh()        // fresh battery, storage and file list (on a sheet's appear)
actions.clearStorage()   // wipes the ring. Confirm first.

RingActions.preview      // does nothing, for previews
```

Also `disconnect`, `remove`, `rename`, `setAutoSync(_:)` and `setAutoClear(_:)`.

**Update the firmware** with `Museo.firmware`, an `ObservableObject` updater that sends the image bundled in the kit.

```swift
Museo.firmware.start()     // phase: .preparing, .sending(progress:), .confirming, .resetting, .success, .failed
BundledFirmware.version    // "10.14"
```

**Setup** runs on its own through `RingActions`. `RingSetup.isEnabled` says whether the app's Info.plist turns AccessorySetupKit on, and `RingSetup.shared.logText` holds the last 50 setup events for a console.

`Museo.manager` (the `RingBLEManager`) exists for low-level tools like a ring console. Screens never read it: it publishes many times a second while a recording streams.

## Install

**From GitHub.** File › Add Package Dependencies…, enter `https://github.com/its4ff/museo-kit`, and pin the version museo build uses (`0.2.3`, exact). In a `Package.swift`:

```swift
.package(url: "https://github.com/its4ff/museo-kit", exact: "0.2.3")
```

**Working on the kit itself?** Clone it next to your app's folder and open the app through a workspace that also holds `../museo-kit`. Xcode then uses the local copy in place of the tagged one (museo build's `scripts/local-kit.sh` makes that workspace).

Needs iOS 26 or later, Xcode 26 and Swift tools 6.2. The kit brings in Nordic's [nRF Connect Device Manager](https://github.com/NordicSemiconductor/IOS-nRF-Connect-Device-Manager) 1.14.6 (exact) for firmware updates.

## App setup

**Info.plist.** The app needs these keys. museo build puts the first four in `Info.plist` and the usage string in its target's build settings (`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`).

```xml
<key>NSAccessorySetupKitSupports</key>
<array><string>Bluetooth</string></array>
<key>NSAccessorySetupBluetoothServices</key>
<array><string>0004</string></array>
<key>NSAccessorySetupBluetoothNames</key>
<array><string>Muse</string></array>
<key>UIBackgroundModes</key>
<array><string>bluetooth-central</string></array>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>museo links to your ring over bluetooth to bring in what you say.</string>
```

- **The three `NSAccessorySetup…` keys** turn on AccessorySetupKit: the ring is set up through iOS's sheet, and there's no Bluetooth prompt. The service and name must match what the kit's sheet looks for (`0004`, `Muse`), or iOS refuses to show it. The sheet matches on those two, so no company identifier key is needed.
- **Both ring names are set up.** The sheet matches "Muse", so it finds `Museo_47cf` (firmware 10.14 and later) and `Muse_47cf` (earlier firmware).
- **Without them,** setup falls back to a plain Bluetooth scan that connects the closest ring with "Muse" in its name that answers, and iOS asks for Bluetooth permission the usual way. Remove all three, never one.
- **`bluetooth-central`** lets recordings come in while the app is in the background, and lets iOS relaunch the app for the ring.
- **`NSBluetoothAlwaysUsageDescription`** is the line iOS shows if it asks for Bluetooth (the plain-scan fallback). Keep it either way.

**The product image.** iOS's sheet shows the ring's name (`Museo.start(name:)`) next to a picture the kit bundles: `MuseRingAccessory` in `Sources/MuseoKit/Resources/Media.xcassets`, the ring render in its natural finish at the sheet's size (180 by 120 points, @1x to @3x, transparent, so it reads on light and dark sheets). If it's missing, the sheet shows an SF Symbol. An app can't swap the picture today; that's a kit change. The first app to set a ring up names it for every app on the phone: when another app got there first, iOS shows that app's name and picture instead.

## Rules

- **Sealed.** Apps import `MuseoKit` and nothing else from here. Never edit, copy, wrap or fork its files. No `CoreBluetooth` or second Bluetooth stack in the app, never create a `RingBLEManager`, and never set its `on…` callbacks (the kit owns them; use `Museo.onEvent`). Need something it doesn't do? Ask for a kit change.
- **One ring app per phone.** Two apps on one ring split its recordings between them: one can clear what the other hasn't brought in. `clearsRingAfterSync` is off by default for this reason, so the ring keeps every recording until someone clears it.
- **Save before the ring lets go.** Return true from `onCapture` only once the recording is on disk. Never call `clearRingStorage` from code that runs on its own.
- **Always 24 kbps.** The kit sets the ring to 24 kbps on every connect. There's no setting, and none should be added.

## What lives where

| Target | What's in it | Built as |
|---|---|---|
| `MuseoCore` | `RingBLEManager`: Bluetooth, the ring's protocol (Treaty), live capture, offline sync, Opus to WAV decoding | Swift 5 mode, no default actor |
| `MuseoKit` | what apps use: `Museo`, `RingModel` and `RingStatus`, `RingActions`, `RingSetup` (AccessorySetupKit), `RingEvent`, `RingFirmwareUpdater` and `BundledFirmware`, the capture hand-off and its ledger | main actor by default, approachable concurrency |

Apps import `MuseoKit` only. It re-exports the core's public types (`RingBLEManager`, `CompletedCapture`, `CaptureSource`, `RingFile`, `RingSystemState`). The calls that could retire a ring copy without a save, or take a capture before `Museo.onCapture` sees it (`markOfflineSynced`, `drainCaptures`, the manager's `on…` callbacks), are `package`: only MuseoKit can use them.

Bundled resources: `Resources/MuseRing.zip` (the firmware image, `BundledFirmware.stamp`) and `Resources/Media.xcassets` (the setup sheet's picture).

Files the kit keeps on the phone:
- `Documents/MuseBuildCaptures/` (`RingBLEManager.capturesDirectory`): each recording as a WAV (16 kHz mono, 16-bit) plus the ring's Opus.
- `Application Support/MuseoKit/imported-keys.json`: every ring recording ever brought in. Never trimmed, so a recording whose muse you deleted never comes back.

## Versioning

Semantic versioning, with every change in `CHANGELOG.md`:
- **major** when public API is removed or changes meaning
- **minor** for new API, or a new bundled firmware image (replace the zip, set `BundledFirmware.stamp` to the manifest's `time` as yyyyMMdd)
- **patch** for fixes that change no API

Tags are plain versions (`0.1.0`). While the kit is below 1.0, pin an exact version: any 0.x release can change the API.

## Status

Preview (0.x). The source is public so you can read it and build on it through MuseoKit. No license yet, so all rights reserved: please don't copy it into other projects.

Firmware updates use Nordic Semiconductor's nRF Connect Device Manager (`iOSMcuManagerLibrary`, Apache 2.0) and its dependencies.
