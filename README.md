# Digital Paper for macOS

A native macOS app for managing Sony Digital Paper devices (DPT-RP1, DPT-CP1)
and the Fujitsu Quaderno — a graphical replacement for Sony's discontinued
Digital Paper App and the [`dpt-rp1-py`](https://github.com/janten/dpt-rp1-py)
command-line tool.

The device protocol is reimplemented natively in Swift (no Python dependency):
mDNS discovery, the Diffie-Hellman pairing handshake, RSA-SHA256 session auth,
and the full document/Wi-Fi/system/template REST API.

<p align="center">
  <img src="docs/screenshot.png" alt="Digital Paper for macOS — document browser" width="700">
</p>

## Features

- **Guided pairing** — discover devices on the network, pair with the on-device
  PIN, or import credentials already created by `dpt-rp1-py` / Sony's app.
- **Document browser** — folders, drag-and-drop upload, download, delete,
  rename, move, and "open on device".
- **Device status** — battery, storage, firmware in the sidebar.
- **Wi-Fi** — enable/disable, list/scan/add/remove networks.
- **System** — owner, time zone, and screenshot capture.
- **Templates** — list, upload, delete note templates.
- **Sync** — two-way folder sync (newest wins) with a change preview.

## Architecture

| Module | Responsibility |
|---|---|
| `DigitalPaperKit` | Protocol + crypto + networking (no UI). `DigitalPaperClient` actor, `Registration`, `DeviceDiscovery`, `CredentialStore`, and the `Crypto/` port. |
| `DigitalPaper` | SwiftUI app: `AppModel` + feature view models and views. |
| `DigitalPaperKitTests` | Validates the crypto port byte-for-byte against `dpt-rp1-py` reference vectors. |

Credentials are stored in the Keychain, keyed by device serial.

## Build & Run

Requires Xcode 16+ and [XcodeGen](https://github.com/yonyz/XcodeGen)
(`brew install xcodegen`).

```bash
xcodegen generate
open DigitalPaper.xcodeproj      # or build from the CLI:
xcodebuild -project DigitalPaper.xcodeproj -scheme DigitalPaper \
  -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild -project DigitalPaper.xcodeproj -scheme DigitalPaper \
  -destination 'platform=macOS' test -only-testing:DigitalPaperKitTests
```

Reference crypto vectors are regenerated with `python3 tools/gen_vectors.py`
(requires the `cryptography` package).

## Release (Developer ID, notarized)

See `scripts/release.sh` for the signed + notarized + stapled build.

## Credit

Protocol reverse-engineering is based on the excellent
[`dpt-rp1-py`](https://github.com/janten/dpt-rp1-py) project.
