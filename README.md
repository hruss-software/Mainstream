# Photon

Screen-to-camera data link for iOS. One phone shows an animated colour code, the other reads it with the camera. It can send text, photos, audio recordings and any file.

Open `Photon.xcodeproj` (or run `xcodegen generate` after editing `project.yml`). Choose your signing team, then run on two devices. The Run scheme uses the Release configuration because the decoder needs optimisation to keep up with the camera.

## Using it
- **Receive:** the app opens on the camera. Point it at the sender's screen. A ring shows progress and the live rate. A chevron means the receiver has spare error-correction margin (↑) or is losing too much (↓).
- **Send:** tap the text, photo, audio or file icon.
  - Swipe up or down on the code to change density (cells, bits per cell and parity).
  - Swipe left or right to change the frame rate (60, 30, 20 fps and slower).
  - Your last choices are remembered.

## How it works (`PhotonCore`)
| Layer | Choice |
|---|---|
| Fountain | Systematic random linear code over GF(2), blocks of ≤1024 × 180-byte symbols, online Gaussian elimination. Rateless, so dropped frames only cost time. Overhead is about 1–2%. |
| Packet | 7-byte header, 180-byte payload, CRC-32, Reed–Solomon parity (32–64 bytes). Every packet carries its own identity, so torn or blended camera frames still yield their clean regions. |
| RS decode | Errors and erasures. Bytes with the lowest soft confidence are erased first when plain decoding fails. |
| Frame | 4 QR-style finders, a level/aspect header (CRC-16, any rotation), 5×5 alignment markers every ~24 cells (corrects lens and perspective error), and codewords packed into 16×16-cell tiles. |
| Modulation | 1, 2 (green/magenta) or 3 (RGB) bits per cell, scrambled so data is balanced. The receiver applies per-cell local mean/σ normalisation and a blind 3×3 colour-crosstalk inverse. |
| Camera | Highest-resolution 60 fps format (4K60 on recent iPhones), BGRA, exposure capped at 1/250 s with −0.7 EV, near-range autofocus, stabilisation off. |

## Rate tuning
`swift run -c release PhotonSim` sweeps the ladder through a synthetic channel. The channel models perspective, blur, sub-pixel moiré, crosstalk, noise and vignetting. `TEMPORAL=1` adds display scan-out, rolling shutter and exposure blending. `DECODE=shot.png` decodes a screenshot of the sender.

In simulation, goodput rises with density until RS failures start to dominate, then falls off a cliff. Good conditions peak at level 12 and above (≈1–1.6 MB/s). Soft or distant conditions peak around levels 6–7 (≈300–400 kB/s). 60 fps frames beat 30 fps by 40–65% when the receiver processes 60 fps. The default is level 7 at 60 fps. The receiver's chevron tells you which way to move toward the crossover for your devices, distance and lighting.
