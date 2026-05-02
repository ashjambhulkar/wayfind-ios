# Screenshot automation

## Intent

`capture_screenshots.sh` boots an **iOS Simulator**, runs **`wayfindUITests`** (`ScreenshotUITests`), and writes PNGs under **`screenshots/output/`** when `SCREENSHOTS_DIR` is set (the script exports it to the repo-relative output path).

Make the script executable once:

```bash
chmod +x screenshots/capture_screenshots.sh
```

## Prerequisites

- **Xcode** with a Simulator matching `SIM_NAME` / `SIM_OS` (defaults below).
- **Debug** build: UI testing uses launch argument **`-wayfind-ui-testing`**, which (in **DEBUG only**) forces **`AppConfig.useRealBackend == false`** so the existing **mock `DataService`** runs — **no Supabase sign-in** and **no flaky network** for the scripted path.
- **Code signing**: same team as the project (`DEVELOPMENT_TEAM` in Xcode).

## Limitations

| Topic | Detail |
|--------|--------|
| **Release / TestFlight** | The `-wayfind-ui-testing` gate is **`#if DEBUG`**. Production builds are unchanged. |
| **Live backend** | Without that launch argument, the app uses real Supabase. There is **no** automated bypass; sign in manually (or extend tests with a dedicated test account — not shipped here). |
| **Coverage** | `ScreenshotUITests` hits a **subset** of `SCREENS.md` (~7 PNGs). Map, documents hub tab, checklists, AI wizard, paywall, invites, and most nested sheets are **manual / future tests**. |
| **Simulator runtime** | If `iPhone 16 (iOS 18.1)` is missing, install that runtime in Xcode or override **`DESTINATION`** (see script header). |

## Environment overrides

| Variable | Default |
|----------|---------|
| `SCHEME` | `wayfind` |
| `SIM_NAME` | `iPhone 16` |
| `SIM_OS` | `18.1` |
| `SCREENSHOTS_DIR` | `<repo>/screenshots/output` (set by script) |
| `DESTINATION` | If set, used verbatim instead of `name=` + `OS=` |

## Artifacts

- **PNGs:** `screenshots/output/01_sign_in.png` … `07_profile.png` (when tests succeed).
- **Xcode:** `XCTAttachment` screenshots are also kept in the **test result bundle** when using Xcode’s test report UI.
