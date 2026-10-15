# museo kit changelog

## 0.2.3

**Fix: firmware updates sent several times slower than muse OS**
- Nordic's library opens its own bluetooth central for SMP. Its first state is often "not ready", so the upload's request for the ring's buffer size failed, and the library quietly fell back to defaults: one small packet per round trip. On a ring, 7% took about as long as a whole muse OS update.
- The updater now asks the ring for its SMP parameters until that central is up and the ring answers (up to 8 tries, 250 ms apart), as muse OS does, then starts. It also sets the upload's reassembly buffer from the ring's answer, so big writes go even if the library's own request misses.
- Logs `[museo][fw] smp probe N: …` for each try.

## 0.2.2

**Setup finds both ring names again**
- The setup sheet matches "Muse" (`RingSetup.ringNameMatch`), so it lists `Museo_47cf` (firmware 10.14 and later) and `Muse_47cf` (earlier firmware), as muse 54 does. 0.2.0 matched "Museo" only.
- Apps list `Muse` in `NSAccessorySetupBluetoothNames`.
- The plain scan picks rings with "Muse" in the name. `RingStatus.advertisedName` takes names starting `Museo_` or `Muse_`.

## 0.2.1

**Firmware updates: time left, and the screen stays on**
- `RingFirmwareUpdater.estimatedFinishAt`: when the whole update should be done, sending through restart. It starts from this phone's last update speed (about 28 KB/s the first time), follows the measured speed while sending, and only creeps later a little at a time, so a countdown never jumps back. Nil when idle or settled. Ported from muse OS.
- The screen stays on while an update runs (`isIdleTimerDisabled`), so a phone that would lock mid-send doesn't suspend the app before the ring has the whole image.

## 0.2.0

**Firmware 10.14** (`museo_20261014A`)
- `Resources/MuseRing.zip` is the 10.14 image: MCUboot version 1.64.0+0, 434,500 bytes, the same `manifest.json` plus signed, encrypted image as before. `BundledFirmware.stamp` is `20261014`, so `BundledFirmware.version` says "10.14".
- From this image on, the ring advertises `Museo_47cf` instead of `Muse_47cf`.

**Only museo rings are set up**
- The setup sheet always matches the name `Museo` (`RingSetup.ringNameMatch`) with service `0004`. It no longer drops the name filter after an empty sheet, so a ring on older firmware never shows.
- Apps list `Museo` in `NSAccessorySetupBluetoothNames` (it was `Muse_`). iOS refuses the sheet when the two don't match.
- Without AccessorySetupKit, the plain scan picks only rings with `Museo` in the name.
- A ring that was set up before keeps linking (iOS reconnects it by id, not by name), so it can take the 10.14 update. `RingStatus.advertisedName` shows both `Museo_47cf` and `Muse_47cf`.

## 0.1.0

The ring kit leaves the muse build repo and becomes its own package.

**Layout**
- `MuseoCore`: the original ring kit (`RingBLEManager`, Treaty, Opus, offline sync), compiled as before (Swift 5 mode, no default actor).
- `MuseoKit`: what apps use.
  - `Museo.start(name:clearsRingAfterSync:)`
  - `Museo.onCapture`: save first, then the ring retires its copy.
  - `Museo.onEvent` / `Museo.events()`: any number of listeners. The kit owns the manager's single-slot callbacks.
  - `RingModel.status`, `RingActions`, `RingSetup` (AccessorySetupKit), and `RingFirmwareUpdater` with the firmware zip bundled.
- Apps import `MuseoKit` only; it re-exports the core types it hands out.
- The capture hand-off is in the kit:
  - the import ledger (`Application Support/MuseoKit/imported-keys.json`)
  - dropping presses under 1 s
  - handing known files back to the manager before a sync
- Recording is always 24 kbps. There is no setting for it.

**The ring's recording settings reply is read now** (`0x1E`)
- The ring answers `0x1C` with `0x1E`, which the kit dropped before (an unknown command). It's parsed now, so the once-per-connection bitrate check finally runs, and `RingBLEManager.recordingSound` shows the stored noise reduction and AGC values for tools like a console.
- **Noise reduction stays at 0.** A ring that reports another level is set back to 0 once per connection (`0x1D` with 24 kbps, 0, and the ring's own AGC byte unchanged). In testing on 2026-10-14, levels 0, 1 and 2 and AGC values from 50 to 255 changed nothing measurable: the same noise in the pauses (about −60 dB), the same hiss above 3 kHz, no gain. Apps get no setter.

**Setup sheet picture.** `MuseRingAccessory` is the ring render in its natural finish (from the render studio's setup export, 180 by 120 points at @1x to @3x) instead of a drawn circle. A ring set up before may keep the old picture in Settings until it's set up again.

**Live audio: words while you speak** (`Museo.liveAudio()`)
- A hold's audio as it arrives: `.began(Date)`, then `.samples(LiveAudioChunk)` (16 kHz mono 16-bit, about every 100 ms), then `.ended`. `chunk.buffer()` makes an `AVAudioPCMBuffer` for a recognizer.
- `LiveOpusStream` (MuseoCore) cuts frames the way a finished capture does (marker-led 24 kbps CBR frames, the 4-byte stream header stripped), but only from bytes not yet used, and decodes them with one converter for the whole hold. A long hold costs the same per notification as a short one.
- The manager's audio tap is `package` now, and only on while a `liveAudio()` stream is open. Decoding runs on its own queue.
- Verified on macOS: decoded in pieces of 1, 6 and 100 frames, the samples match the whole-capture decoder exactly; frames are all found in order, and one lost notification loses only its own frames. **Still to check with a ring.**
- The finished capture is untouched: it still decodes from all of its notifications and reaches `onCapture` as before.

**Fix: recordings of about 10 s hung the decoder forever** (`OpusWavDecoder.decodeBatch`).
- Apple's Opus decoder can spin forever when handed about 1,000 packets in one buffer. In a desktop test, 993 to 1,008 packets hung and 992 and 1,009 decoded.
- That wedged the decode queue. Offline sync stopped for good (the same file came back each launch and hung again), and live takes were lost for the rest of the session.
- The decoder now keeps one converter for the whole recording and feeds it 100 packets at a time, as museum's `MuseumRingDecoder` does since 2026-10-07.
- Verified on macOS: 993, 1,000, 1,008 and 4,000 packets decode in milliseconds where the old code hung at 993. **Still to check on an iPhone.**

**Safety fixes from review**
- The import ledger keys recordings by the ring's wall clock, not seconds since 1970 read in the iphone's time zone. A trip across time zones no longer brings deleted muses back or re-downloads the ring.
- A live capture the app couldn't save (`onCapture` returned false) is kept and offered again, since the ring has no copy of it.
- The import ledger never replaces itself with a partial one: when its file is there but can't be read yet (the ring woke the app before the iphone was first unlocked), it reads it again on the next use and merges what it learned meanwhile.
- Auto clear ("clear the ring once they're safe") no longer wipes a file that couldn't be decoded.
- A memory recording with no date from the ring gets the ring's file name in its own, so two decoded in the same second can't share one.
- `markOfflineSynced`, `drainCaptures` and the manager's `on…` callbacks are `package`: an app can't retire a ring copy without a save, or take a capture before `Museo.onCapture` sees it.
- The kit's copy says click, not tap ("click it to wake it").

**Battery and slow links (from the muse OS handoff, 10-09)**
- A recording that stops while the ring reports no files no longer triggers a file list (each list wakes the ring's fast link).
- The first list reply waits 4 s (was 2.5 s) and a download stall 3 s (was 1.5 s): right after a reconnect the ring needs about 4.5 s to get back to its fast link, and the old timers stalled healthy downloads into partial ones.

**Known, for the kit owner**
- `disconnect()` sends stop recording (`0x17 00`), so tapping disconnect ends a memory recording.
- The bundled firmware (9.06, `20260906`) is older than the build the 10-05 ring tests ran (`20260919B`, reports 1.62). The kit can't read the ring's version yet, so "update" may install an older image.
- Offline sync hardening from museum is not ported yet:
  - longer idle timeouts in the background
  - end-gap repair
  - file ids that include the timestamp
  - CRC and file-list retries
  - the UTC ring clock
- One-click and three-click are media keys handled by iOS. The key map commands (`0x1F` / `0x20`) exist, but what their byte values mean is undocumented.
