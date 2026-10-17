# mainstream

An iOS app that sends text, photos (from the library or taken in the app), audio recordings and any file between phones over three links:

| Mode | Link | Simulated goodput |
|---|---|---|
| ▦ Screen | Animated colour code, read by the camera | ~0.4–1.9 MB/s depending on focus and distance |
| 〰 Sound | OFDM over speaker → microphone: audible (0.5–15 kHz), whole range (0.2–20.5 kHz) or near-ultrasonic (17.5–21.5 kHz) | Measured through a real MacBook speaker and mic: 3 kB files in ~7–13 s on audible or whole range. Near-ultrasonic didn't get through that speaker. |
| 🎞 Hidden | Data hidden in an ordinary video you pick, read by the camera | ~3–12 kB/s in simulation with a steady or slightly defocused camera |

## Build
Open `mainstream.xcodeproj` in Xcode 27.1, or run `xcodegen generate` after editing `project.yml`. Choose your signing team and run on two devices. The Run scheme uses Release because the decoders need optimisation to keep up.

## Using it
- The top-left picker selects the mode for both receiving and sending.
- **Camera controls (right edge):**
  - Tap the preview to focus there.
  - The slider sets the lens position manually (top = far, bottom = macro).
  - The viewfinder button returns to continuous autofocus.
  - The camera-pair button (on phones that support it) runs the wide and ultra-wide cameras together.
- **Payload bar:** text, photo library, take a photo, record audio, file.
- **Senders:**
  - Screen: sliders for density and frame rate.
  - Sound: band buttons and a rate slider.
  - Hidden: pick a cover video, then sliders for density and strength (how visible the overlay is).
- The receiver shows a progress ring and the live rate. A chevron says whether there's spare error-correction margin (↑, try denser or faster) or too much loss (↓).
- **Sound tips:**
  - Put the sender's volume at maximum and hold the phones 10–30 cm apart, speaker toward microphone.
  - The ring follows the microphone level, and a green pulse marks each frame the receiver hears.
  - A red crossed-out mic means microphone access is off for the app.
- **Hidden-video tips:**
  - Rest the receiving phone on something, or hold it very steady.
  - Nudge focus slightly soft with the slider: sharp focus picks up screen moiré.
  - The thumbnail in the top right shows what the demodulator sees. Grey means no signal. A faint code pattern means it's working, and the frame turns green when the code is locked.

## How it works (`Core`, module `MainstreamCore`)
| Layer | Choice |
|---|---|
| Fountain | Systematic random linear code over GF(2). Blocks hold ≤1024 symbols of 180 bytes, with online Gaussian elimination. It's rateless, so lost packets only cost time. Overhead ≈1–2%. |
| Packet | 7-byte header, 180-byte payload, CRC-32, Reed–Solomon parity (32–64 bytes). Decoding handles errors and erasures, using the least-confident bytes as erasures. |
| Screen frame | 4 finders (3 are enough). A CRC-16 header works in any rotation. 5×5 alignment markers sit every ~24 cells, and each codeword covers a near-square patch. |
| Screen receiver | Per-cell local normalisation and blind colour-crosstalk inversion. A decision-feedback inter-cell equaliser roughly doubles goodput under defocus in simulation. |
| Hidden video | The code is drawn over the video at opacity α. It alternates with its complement on every 60 Hz refresh, so viewers see only a faint uniform haze. The receiver sums ±1-weighted 8-frame windows of 60 fps captures to recover the code. It tracks polarity per region, because tearing can invert parts of the image. |
| Sound | 2048-point OFDM with a 1024-sample (21 ms) cyclic prefix, which outlasts the strong room echoes measured at 8–16 ms. Chirp sync is followed by a 43 ms gap so the chirp's echo dies away. Every 8th carrier is a known pilot: one frame-wide slope (clock offset) and a per-symbol phase are fitted to them, so drift is removed without depending on decisions. Data is BPSK/QPSK/8PSK phase steps. Each packet is decoded two ways: coherently, against a channel estimate refined over three passes, and differentially. The CRC picks the one that's right. Each codeword byte stays on one carrier, and bytes on carriers that were weak across the frame are erased first. |
| Camera | 60 fps at the highest resolution available (4K60 when single). Exposure is capped at 1/250 s, with −0.7 EV, near-range autofocus and stabilisation off. Multi-camera mode feeds both cameras into one transfer. That gives diversity (a second look and a different focus distance) rather than double the raw rate. |

## Simulation and tests
`swift test -c release` in `Core` covers Reed–Solomon, the fountain code, the end-to-end camera link, hidden-video recovery and an audio round trip on every band.

`swift run -c release MainstreamSim` sweeps the screen ladder through a synthetic camera. The camera model includes perspective, blur, moiré, crosstalk, noise and vignetting. Environment switches select other runs:

| Switch | Runs |
|---|---|
| `TEMPORAL=1` | Display scan-out and rolling shutter |
| `HIDDEN=1` | The hidden-video channel (`SHAKE=` adds hand shake) |
| `AUDIO=1` | The acoustic modem through a simulated room (echoes, reverb, 40 ppm clock offset, noise) |
| `DECODE=shot.png` | Decodes a screenshot of the sender |

Findings that shaped the defaults:
- **Screen:** goodput climbs with density until Reed–Solomon failures dominate, then falls off a cliff. 60 fps frames beat 30 fps.
- **Hidden video:** moiré combined with hand shake is the limit. Optical defocus helps, but digital smoothing and frame registration did not, so neither is in the app.
- **Sound:** a real speaker-to-mic test (`WAV=` to write a transmission, `DECODEWAV=` to decode a recording, `CHANNEL=` to measure echoes and clock drift, `GENIE=` to compare against the sent symbols) changed the design. Echoes outlasted the old 5 ms guard. Frequencies below ~4 kHz and above ~18 kHz were weak on the test speaker. Decision-driven phase tracking fell apart on noisy pilots. The default is now 2-phase at the strongest parity, and the faster rates need a quiet room and close range.
