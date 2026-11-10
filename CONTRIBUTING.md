# Contributing to PocketMac

Thanks for wanting to make PocketMac better! Bug fixes, new features, better docs and translations are all welcome. This page explains how to build each app, how to test your change, and how to send it.

New to the code? Read [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) first: it has a map of every folder.

## Quick start

1. **Fork** this repository on GitHub and clone your fork.
2. Make your change on a new branch.
3. Push it. GitHub Actions in your fork builds and tests the apps you touched (Mac, iPhone, Android).
4. Open a **pull request**. Say what you changed and how you tested it.

You don't need Xcode or Android Studio: GitHub Actions builds the iPhone `.ipa` and the Android `.apk` for you. Download them from the **Actions** tab → your run → **Artifacts**.

## The Mac app (`Host/`)

Needs only the free **Command Line Tools** (`xcode-select --install`), macOS 14 or newer.

```bash
tools/build-host.sh
```

```bash
open "build/PocketMac Host.app"
```

- Every rebuild gets a new ad-hoc signature, so macOS asks for Screen Recording and Accessibility again. To keep the permissions across rebuilds, make a local signing identity once with `tools/setup-signing.sh`.
- `tools/make-dmg.sh` builds the universal (Apple Silicon + Intel) app and `dist/PocketMac-Host.dmg`.
- **Don't use SwiftUI macros** (`@State`, `@Observable`, `#Preview`): the Command Line Tools don't include the macro plugins. Use `ObservableObject` + `@Published` and `@ObservedObject` instead (in the iPhone app too, because `tools/check-ios.sh` type-checks it with the same tools).

### Testing without touching your own screen

`tools/run-tests.sh` starts a throw-away **test host** (the real app with a test picture instead of screen capture, on localhost, its own settings folder) and runs 18 end-to-end checks with `tools/pmtest`, a command-line phone:

```bash
tools/run-tests.sh /tmp/pocketmac-tests
```

When you run test hosts by hand, always set `POCKETMAC_PRIVACY_DRYRUN=1` (`tools/test-host.sh` does): otherwise privacy mode really darkens and locks the Mac you're working on.

| Variable | Effect |
|---|---|
| `POCKETMAC_TEST_PATTERN=1` / `=desktop` | Stream a moving test picture / the demo desktop instead of the screen |
| `POCKETMAC_PORT=47811` | Listen on another port |
| `POCKETMAC_LOOPBACK=1` | Accept connections from this Mac only |
| `POCKETMAC_HEADLESS=1` | No menu bar icon or windows |
| `POCKETMAC_CONFIG_DIR=…` | Separate settings, keys and paired phones |
| `POCKETMAC_SET_PASSWORD=…` | Set the password at start-up |
| `POCKETMAC_PRIVACY_DRYRUN=1` | Only log what privacy mode would do |

## The iPhone app (`iOS/`)

- **In the cloud (no Xcode):** push to your fork; the **Build iPhone app (.ipa)** workflow makes an unsigned `PocketMac.ipa`. Install it with Sideloadly (see the README).
- **With Xcode:** `brew install xcodegen`, then `cd iOS && xcodegen generate` and open `PocketMac.xcodeproj`. Choose your own team and bundle ID to run it on your phone.
- Without Xcode you can still catch compile errors: `tools/check-ios.sh` type-checks the app against Mac Catalyst, and `tools/test-catalyst.sh /tmp/pm-cat` runs it as a Mac app connected to a test host.

## The Android app (`android/`)

Kotlin + Jetpack Compose, minimum Android 8 (API 26), target Android 17 (API 37).

- **In the cloud:** push to your fork; **Build Android app (.apk)** runs the unit tests, builds the APK, then runs the emulator tests and uploads screenshots of every screen (**device-results**).
- **Locally:** open `android/` in Android Studio, or run `gradle -p android assembleDebug testDebugUnitTest` with JDK 21 and Gradle 9.6.
- Release builds are signed only when the `POCKETMAC_KEYSTORE_B64` and `POCKETMAC_KEYSTORE_PASSWORD` secrets exist. In forks and pull requests the debug key is used instead, which is fine for testing.

## Changing the protocol

The Mac and iPhone apps share `Shared/`. The Android app has its own Kotlin copy in `android/.../proto/`, and **the two must stay byte for byte identical**. If you change anything in `Shared/` (messages, handshake, crypto):

1. Make the same change in the Kotlin code.
2. Regenerate the test data from the Swift code:
   ```bash
   tools/make-vectors.sh /tmp/pm-vectors
   ```
3. Commit the changed `vectors.txt` and recordings. `ProtocolVectorsTest` fails if the two sides differ.

Add new message types instead of changing old ones: unknown types are ignored, so old and new apps keep working together. Bump `Handshake.version` only for a change that can't be compatible.

## Pull request checklist

- [ ] It builds, and the tests for the parts you touched pass (Actions shows green ticks).
- [ ] Protocol changes are made on both sides, with new vectors.
- [ ] New or changed screens: attach a screenshot.
- [ ] User-visible changes are described in the README if needed.
- [ ] No personal data, keys or passwords in the code, tests or screenshots.

## Ideas to work on

- Mac **audio** on the phone (ScreenCaptureKit audio → AAC)
- **File transfer**: send photos to the Mac's Downloads folder, fetch files from the Mac
- **Several displays**: choose which screen to view
- **iPad** layout and hardware keyboard / mouse on iPhone and iPad
- **Widgets and Shortcuts**: "Lock my Mac", "Mac battery"
- **Translations** of the apps

Open an issue first for bigger changes, so we can agree on the approach before you spend time on it.

## Making a release (maintainers)

1. Bump the version: `CFBundleShortVersionString` in `Host/Info.plist`, `MARKETING_VERSION` in `iOS/project.yml`, and `versionName` in `android/app/build.gradle.kts` (its last number is the build number, set automatically).
2. Push to `main` and wait for the three workflows to pass.
3. Build the Mac app with the stable signing identity (keeps users' permissions across updates): `tools/make-dmg.sh`.
4. Download `PocketMac.apk` and `PocketMac.ipa` from the workflow runs of that commit.
5. Create a GitHub release with a `vX.Y.Z` tag and attach all three files plus `SHA256SUMS.txt` (`shasum -a 256 PocketMac* > SHA256SUMS.txt`).

## Code of conduct

Be kind and patient. Everyone was new once. Harassment or insults aren't welcome here.
