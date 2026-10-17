# Mainstream

An iOS app that sends text, photos (from the library or taken in the app), audio recordings and any file between phones over two links:

| Mode | Link | Speed |
|---|---|---|
| ▦ Screen | Animated colour code, read by the camera | ~0.4–1.9 MB/s in simulation, depending on focus and distance |
| 〰 Sound | Coded OFDM over speaker → microphone: audible (0.5–15 kHz), whole range (0.2–20.5 kHz) or near-ultrasonic (17.5–21.5 kHz) | ~0.35–2 kB/s nominal by rate; ~0.9 kB/s of payload simulated through a channel shaped like a measured laptop speaker |

## Build
Open `Mainstream.xcodeproj` in Xcode 27.1, or run `xcodegen generate` after editing `project.yml`. Choose your signing team and run on two devices. The Run scheme uses Release because the decoders need optimisation to keep up.

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
- The receiver shows a progress ring and the live rate. A chevron says whether there's spare error-correction margin (↑, try denser or faster) or too much loss (↓).
- **Sound tips:**
  - Put the sender's volume at maximum and hold the phones 10–30 cm apart, speaker toward microphone.
  - The ring follows the microphone level, and a green pulse marks each frame the receiver hears.
  - A red crossed-out mic means microphone access is off for the app.

## How it works (`Core`, module `MainstreamCore`)
| Layer | Choice |
|---|---|
| Fountain | Systematic random linear code over GF(2). Blocks hold ≤1024 symbols of 180 bytes, with online Gaussian elimination. It's rateless, so lost packets only cost time. Overhead ≈1–2%. |
| Packet | 7-byte header, 180-byte payload, CRC-32, Reed–Solomon parity (32–64 bytes). Decoding handles errors and erasures, using the least-confident bytes as erasures. |
| Screen frame | 4 finders (3 are enough). A CRC-16 header works in any rotation. 5×5 alignment markers sit every ~24 cells, and each codeword covers a near-square patch. |
| Screen receiver | Per-cell local normalisation and blind colour-crosstalk inversion. A decision-feedback inter-cell equaliser roughly doubles goodput under defocus in simulation. |
| Camera | 60 fps at the highest resolution available (4K60 when single). Exposure is capped at 1/250 s, with −0.7 EV, near-range autofocus and stabilisation off. Multi-camera mode feeds both cameras into one transfer. That gives diversity (a second look and a different focus distance) rather than double the raw rate. |
| Sound frame | A chirp, a 43 ms gap for its echo to die, then reference and header symbols. About 4 s of data follows, so sync costs ~6% of airtime instead of ~25%. Symbols are 2048-point OFDM with a 1024-sample (21 ms) cyclic prefix, which outlasts the room echoes measured at 8–16 ms. |
| Sound tracking | Every 8th carrier is a known pilot. One frame-wide clock-offset slope and a per-symbol phase are fitted to them, so drift is removed without relying on decisions. Each carrier's channel is estimated over three passes from the known symbols, pilots and confident decisions within a ±10-symbol window. |
| Sound coding | Reed–Solomon packets are wrapped in a rate-½ or ¾ convolutional code (K = 7, 171/133). The coded bits are interleaved across all carriers and symbols and carried on BPSK or QPSK. They're decoded with soft-decision Viterbi, where each carrier's bits are weighted by its measured noise, so weak frequencies simply count for less. |

## Simulation and tests
`swift test -c release` in `Core` covers Reed–Solomon, the fountain code, the end-to-end camera link and an audio round trip on every band.

`swift run -c release MainstreamSim` sweeps the screen ladder through a synthetic camera. The camera model includes perspective, blur, moiré, crosstalk, noise and vignetting. Environment switches select other runs:

| Switch | Runs |
|---|---|
| `TEMPORAL=1` | Display scan-out and rolling shutter |
| `AUDIO=1` | The acoustic modem through a simulated room (echoes, reverb, clock offset, noise; `LOWCUT=`/`HIGHCUT=` shape the speaker) |
| `WAV=` / `DECODEWAV=` | Write a sound transmission to a file / decode a recording of one |
| `CHANNEL=` | Measures echoes and clock drift in a recording |
| `GENIE=tx.wav,rx.wav` | Compares a recording's decisions against what was sent |
| `DECODE=shot.png` | Decodes a screenshot of the screen sender |

Findings that shaped the design:
- **Screen:** goodput climbs with density until Reed–Solomon failures dominate, then falls off a cliff. 60 fps frames beat 30 fps.
- **Sound, measured on a real laptop speaker and microphone:**
  - Echoes outlasted a 5 ms guard interval.
  - Frequencies below ~4 kHz and above ~18 kHz were weak.
  - Uncoded BPSK still saw 5–12% symbol errors, which only soft-decision convolutional coding can absorb.
  - Short frames spent a quarter of their airtime on chirps.
