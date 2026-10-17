# Mainstream

An iOS app that sends text, photos (from the library or taken in the app), audio recordings and any file between phones over two links:

| Mode | Link | Speed |
|---|---|---|
| ▦ Screen | Animated colour code, read by the camera | ~0.4–1.9 MB/s in simulation, depending on focus and distance |
| 〰 Sound | Coded OFDM over speaker → microphone: audible (0.5–15 kHz), whole range (0.2–20.5 kHz) or near-ultrasonic (17.5–21.5 kHz) | ~0.35–5 kB/s nominal across six rates (BPSK to 64-QAM); which rate gets through depends on the room, and the receiver says when to go faster or slower |

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
- The top-right gauge always shows how much has arrived and the live rate. A chevron says when the sender should go denser or faster (↑) or back off (↓). For sound, ↑ is based on the channel capacity the receiver measures, so it appears only when the next rate would get through.
- The sound sender shows the speed of the selected rate under its slider.
- **Sound tips:**
  - Put the sender's volume at maximum and hold the phones 10–30 cm apart, speaker toward microphone.
  - The ring follows the microphone level. It stays green while frames are arriving, and a pulse marks each frame's sync.
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
| Sound tracking | Every 8th carrier is a known pilot. Clock offset comes from a straight-line fit of each pilot's phase rate against frequency, and a common phase is fitted per symbol, so drift is removed without relying on decisions. Real speakers change their phase response after the silent gap (their DSP settles), so the channel the data sees is taken from the pilots (averaged over ±8 symbols, interpolated across frequency) rather than from the reference symbol. Confident decisions refine it per carrier, but a refinement that swings by half a constellation step is rejected. |
| Sound coding | Reed–Solomon packets are wrapped in a rate-½ or ¾ convolutional code (K = 7, 171/133). The coded bits are interleaved across all carriers and symbols and carried on Gray-mapped BPSK, QPSK, 16-QAM or 64-QAM (six rates from BPSK ½ to 64-QAM ¾). They're decoded with max-log soft bits and soft-decision Viterbi, where each carrier's bits are weighted by its noise (measured on the pilots, so a carrier whose decisions are mostly wrong can't look clean), so weak frequencies simply count for less. |

Sound rate hint: each frame, the receiver estimates the channel's capacity in bits per carrier from the pilot-measured noise of every carrier. The room simulator calibrated how much capacity each rate needs (`Acoustic.capacityNeeded`), and ↑ appears when the measured capacity clears the next rate's requirement.

The app icon is drawn by `Tools/make-icon.swift` (instructions at the top of the file).

## Simulation and tests
`swift test -c release` in `Core` covers Reed–Solomon, the fountain code, the end-to-end camera link, an audio round trip on every band, every sound rate, and the constellations.

`swift run -c release MainstreamSim` sweeps the screen ladder through a synthetic camera. The camera model includes perspective, blur, moiré, crosstalk, noise and vignetting. Environment switches select other runs:

| Switch | Runs |
|---|---|
| `TEMPORAL=1` | Display scan-out and rolling shutter |
| `AUDIO=1` | The acoustic modem through a simulated room (echoes, reverb, clock offset, noise; `LOWCUT=`/`HIGHCUT=` shape the speaker; `CAPLOG=1` logs each frame's capacity estimate against its result) |
| `WAV=` / `DECODEWAV=` | Write a sound transmission to a file / decode a recording of one |
| `CHANNEL=` | Measures echoes and clock drift in a recording |
| `GENIE=tx.wav,rx.wav` | Compares a recording's decisions against what was sent, with error rate and residual phase by frequency |
| `PILOTS=rx.wav` | Per-pilot phase rates in a recording, and the clock offset they imply |
| `DECODE=shot.png` | Decodes a screenshot of the screen sender |

Findings that shaped the design:
- **Screen:** goodput climbs with density until Reed–Solomon failures dominate, then falls off a cliff. 60 fps frames beat 30 fps.
- **Sound, measured on a real laptop speaker and microphone:**
  - Echoes outlasted a 5 ms guard interval.
  - Frequencies below ~4 kHz and above ~18 kHz were weak.
  - Uncoded BPSK still saw 5–12% symbol errors, which only soft-decision convolutional coding can absorb.
  - Short frames spent a quarter of their airtime on chirps.
  - The speaker's phase response shifted by up to ±1.2 rad, smoothly across frequency, between the reference symbol and the data that followed. Trusting the reference locked whole frequency regions onto a rotated constellation.
