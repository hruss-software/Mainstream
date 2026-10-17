# Mainstream

An iOS app that sends text, photos (from the library or taken in the app), audio recordings and any file between phones as an animated colour code: one phone shows it, the other reads it with its camera. In simulation it moves ~0.4–1.9 MB/s, depending on focus and distance.

## Build
Open `Mainstream.xcodeproj` in Xcode 27.1, or run `xcodegen generate` after editing `project.yml`. Choose your signing team and run on two devices. The Run scheme uses Release because the decoder needs optimisation to keep up.

## Using it
- **Camera controls (right edge):**
  - Tap the preview to focus there.
  - The slider sets the lens position manually (top = far, bottom = macro).
  - The viewfinder button returns to continuous autofocus.
  - The camera-pair button (on phones that support it) runs the wide and ultra-wide cameras together. If the pair fails or the phone gets too hot, the app carries on with one camera and turns the button off.
- **Payload bar:** text, photo library, take a photo, record audio, file.
- **Sender:** sliders for density and frame rate.
- The top-right gauge always shows how much has arrived and the live rate. A chevron says when the sender has spare error-correction margin (↑, try denser or faster) or too much loss (↓).

## How it works (`Core`, module `MainstreamCore`)
| Layer | Choice |
|---|---|
| Fountain | Systematic random linear code over GF(2). Blocks hold ≤1024 symbols of 180 bytes, with online Gaussian elimination. It's rateless, so lost packets only cost time. Overhead ≈1–2%. |
| Packet | 7-byte header, 180-byte payload, CRC-32, Reed–Solomon parity (32–64 bytes). Decoding handles errors and erasures, using the least-confident bytes as erasures. |
| Frame | 4 finders (3 are enough). A CRC-16 header works in any rotation. 5×5 alignment markers sit every ~24 cells, and each codeword covers a near-square patch. |
| Receiver | Per-cell local normalisation and blind colour-crosstalk inversion. A decision-feedback inter-cell equaliser roughly doubles goodput under defocus in simulation. |
| Camera | 60 fps at the highest resolution available (4K60 when single). Exposure is capped at 1/250 s, with −0.7 EV, near-range autofocus and stabilisation off. Multi-camera mode feeds both cameras, at up to 1440p each, into one transfer. That gives diversity (a second look and a different focus distance) rather than double the raw rate. Frame rates are halved under thermal pressure. |

The app icon is drawn by `Tools/make-icon.swift` (instructions at the top of the file).

## Simulation and tests
`swift test -c release` in `Core` covers Reed–Solomon, the fountain code, the layouts and the end-to-end camera link.

`swift run -c release MainstreamSim` sweeps the rate ladder through a synthetic camera. The camera model includes perspective, blur, moiré, crosstalk, noise and vignetting. Environment switches select other runs:

| Switch | Runs |
|---|---|
| `TEMPORAL=1` | Display scan-out and rolling shutter |
| `DECODE=shot.png` | Decodes a screenshot of the sender |

Findings that shaped the design: goodput climbs with density until Reed–Solomon failures dominate, then falls off a cliff. 60 fps frames beat 30 fps.
