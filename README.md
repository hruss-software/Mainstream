<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/mark-dark.png">
    <img src="Docs/mark-light.png" width="112" alt="Mainstream logo">
  </picture>
</p>

# Mainstream

Mainstream moves data between two iPhones without a network. One phone shows an animated colour code and the other reads it with its camera. Text, photos, videos, audio recordings, contacts, Wi-Fi networks, your location and any other file can be sent this way, and the app also appears in the share sheet of other apps.

There are no accounts and nothing goes through a server, so it works in airplane mode or anywhere else the two phones can see each other. The app is in beta on TestFlight.

## Using it

The app opens on the receiver: point the camera at another phone running Mainstream and the transfer starts on its own. The gauge in the top right shows how much has arrived and the current rate. When it shows ↑ the sender can go denser or faster; ↓ means too much is being lost and the sender should back off.

The controls on the right edge are for difficult conditions:

- Tap the preview to focus on a spot, pinch to zoom, or tap the zoom button to step through 1×, 2× and 4×.
- The slider sets focus by hand, far at the top. On phones whose ultra-wide camera focuses closer than the main one, the slider keeps going below the main camera's limit and switches to the ultra-wide for macro.
- The viewfinder button goes back to autofocus.
- The two-camera button (on phones that support it) reads with the wide and ultra-wide cameras at once. If the pair fails or the phone gets hot, the app drops back to one camera and turns the button off.

To send something, use the bar at the bottom: text (with a paste button), a photo or video from the library, a new photo, an audio recording, or a file. The ⋯ button switches the bar to a contact, a Wi-Fi network or your current location. While sending, the two sliders set the density of the code and its frame rate, and the size of the payload is shown at the top. Photos and videos are re-encoded smaller by default; the button next to the size sends the original instead.

What arrives opens with an action that suits it. Links open, Wi-Fi networks can be joined, locations open in a map, contacts can be added, and photos and videos can be saved. Phone numbers, links and addresses in plain text become buttons, and any other file opens in Quick Look.

## Building

You need Xcode 27.1. The app runs on iOS 17 and later, on iPhone and iPad, and needs two devices with cameras to be useful.

Open `Mainstream.xcodeproj`, choose your team under Signing & Capabilities for both the Mainstream and MainstreamShare targets, and run. The project file is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen); if you change targets or settings, edit `project.yml` and run `xcodegen generate` rather than editing the project in Xcode.

If you're building under your own Apple developer account, change the bundle identifiers in `project.yml` (`com.local.mainstream` and `com.local.mainstream.share`) to ones you own. Joining Wi-Fi networks from a received code uses the Hotspot Configuration entitlement, which needs a paid developer membership. On a free account, delete the `entitlements` section of the Mainstream target in `project.yml` and regenerate the project.

The Run action uses the Release configuration, because the decoder is too slow to keep up with the camera in a Debug build. The first launch on a new device under the debugger can sit on a black screen while LLDB loads symbols from the phone; that's Xcode, not the app.

A few launch arguments help during development. Set them in the scheme's Arguments tab; all but the first two only work in a Debug build, so switch the Run configuration to Debug to use them.

| Argument | Effect |
|---|---|
| `-demoSend "text"` | Opens the sender with that text |
| `-demoReceive "text"` | Opens the result screen as if that text had arrived |
| `-viewport 320x568` | Squeezes the UI into a smaller screen, to check layouts |
| `-cycleCams` | Switches between one and two cameras every 2.5 seconds |
| `-demoSendFile /path/IMG.JPG` | Opens the sender with that file |
| `-stillCamera /path/frame.png` | Shows that image in place of the camera, for App Store screenshots |
| `-stillGauge 0.64,612000,1` | Sets the gauge to that progress, rate (bytes/s) and hint |

## How it works

The codec lives in `Core`, a Swift package (`MainstreamCore`) with no UIKit dependency, so it can be tested and benchmarked on a Mac.

| Layer | What it does |
|---|---|
| Compression | Payloads are compressed losslessly when that saves at least 3%, with LZMA up to 4 MB and LZFSE above that. Larger files get a quick trial on their first 256 kB so media that won't shrink is sent as is. The receiver expands to exactly the declared size and refuses anything over 1 GB. |
| Fountain code | A systematic random linear code over GF(2), in blocks of up to 1024 symbols of 180 bytes, decoded by online Gaussian elimination. It's rateless, so a missed frame only costs time. Overhead is about 1–2%. |
| Packets | Each packet has a 7-byte header, 180 bytes of payload and a CRC-32, protected by 32 to 64 bytes of Reed–Solomon parity. The decoder corrects errors and erasures, treating the least confident bytes as erasures. |
| Frames | Four finder patterns (any three are enough), a CRC-16 header that reads in any rotation, and 5×5 alignment markers about every 24 cells. Each codeword is laid out as a near-square patch so blur damages fewer codewords. Cells carry one to three bits of colour. |
| Receiver | Local normalisation per cell, blind correction of colour crosstalk between the screen and the camera, and a decision-feedback equaliser that cancels blur from neighbouring cells. Each camera feeds a small pool of decoders; a dense frame takes 8–12 ms on an M3. |
| Camera | 60 fps at the highest resolution available (4K for a single camera), exposure capped at 1/250 s, −0.7 EV, near-range autofocus and stabilisation off. In two-camera mode each stream is at most 1920 pixels wide, and both feed one transfer. Under thermal pressure the frame rate drops to 30 fps. |

`Shared` holds the sender, which the app and the share extension (`Share`) both use. The app icon and the logo above are drawn by `Tools/make-icon.swift`; the commands are at the top of that file.

## Tests and the simulator

```bash
cd Core
swift test -c release
```

The tests cover Reed–Solomon, the fountain code, compression, the frame layouts and a full encode → screen → camera → decode round trip, plus fuzz tests that feed the decoders noise, badly framed codes, random packets and random codewords. Run them in release; the fuzz tests take many minutes in a debug build.

```bash
swift run -c release MainstreamSim
```

This sweeps the density ladder through a synthetic camera that models perspective, blur, moiré, crosstalk, noise and vignetting, and reports the throughput at each level. In this model a sharp, close 4K capture reaches about 3 MB/s and a badly out-of-focus one about 0.45 MB/s. Real phones will differ, and the app hasn't been benchmarked on devices yet. Environment variables pick other runs:

| Variable | Run |
|---|---|
| `TEMPORAL=1` | Display scan-out and rolling shutter |
| `BENCH=1` | Render and decode time per density level |
| `DECODE=shot.png` | Decodes a screenshot of the sender |
| `CONDS=good,soft` / `LEVELS=8,10` | Limits the sweep to some conditions or levels |

Throughput rises with density until Reed–Solomon starts failing, then drops off sharply, which is why the receiver's ↑/↓ hint watches the error-correction margin rather than the error rate.

## Privacy

Mainstream collects nothing. See [PRIVACY.md](PRIVACY.md) for what each permission is used for.
