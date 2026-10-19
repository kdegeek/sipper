# Sipper BH71 integration

Built from [hybes/sipper](https://github.com/hybes/sipper) commit `e0baa3c9d94b64af60c445bedc446a5f426e9c9f` with native Apple Silicon BH71 support.

## App identity and existing accounts

The build is named **Sipper BH71 Test** with bundle ID `com.hybes.sipper.bh71test`.
Its separate settings directory is `~/Library/Application Support/Sipper BH71 Test`.
The build script leaves `/Applications/Sipper.app` and the original settings directory
intact. It does not automatically import accounts or personal data.

For local validation, existing account, profile, settings, contact, and history JSON
files were copied into the separate directory while the original app was closed.
Account UUIDs were preserved, allowing the BH71 build to read the corresponding
original Keychain password when its own Keychain has no password for that account.
Password edits and removals target only the BH71 build's Keychain service. Removing
a local password still allows read-through to an existing original password.
No new PBX extension is required; no personal account data or credentials are in this repository.

Use one Sipper instance at a time for the same extension to avoid competing SIP
registrations. To switch back, quit Sipper BH71 Test and open the original Sipper.
Settings changes in one copy do not automatically synchronize into the other.
iCloud sync and browser integration are disabled in the BH71 build, and it does
not claim the original app's SIP/tel URL handlers.

## Features

- Hardware answer/end and mute/unmute synchronization.
- Caller name and number on the BH71 workstation screen, using a native USB protocol adapter.
- Incoming, active, outgoing, hold/resume, waiting-call and call-end display updates.
- Workstation screen actions and native HID reports are deduplicated against current call state.
- A hardware test under **Headset → BH71 Workstation…** (Command-Shift-B). It places no SIP call, opens no microphone and ends automatically after two minutes.

These controls apply to calls handled by this Sipper instance. Calls answered independently on a desk phone are not controlled by this app.

## Native Apple Silicon

Sipper, its SIP/audio engine, and its caller-ID helper are now ARM64. The app bundle contains no Intel executables or Yealink SDK dylib and does not require Rosetta. The helper speaks the observed BH71 USB protocol directly. Private stdin/stdout pipes carry call snapshots and button actions; it has no network listener and receives no SIP passwords. Diagnostics omit caller names and numbers.

The first implementation used the Intel Yealink SDK under Rosetta. A native probe subsequently displayed “Native Apple Silicon / 7100” on the connected workstation, confirmed by the user. Native call-control event handling replaced the remaining SDK behavior. See `BH71-NATIVE-PROTOCOL.md` for the documented messages and scope.

This build does not require or install Rosetta. Removing that dependency addresses the architecture warning, but does not guarantee compatibility with an unreleased macOS version. Apple's guidance: https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment

## Validation

- App and helper architecture checks and bundle signature verification passed (ARM64 only).
- 45 call-control checks passed, including duplicate action filtering and hardware hangup after an app-originated answer.
- Password isolation checks passed with synthetic credentials: existing-password reads, local edits, denial handling, and no original-store writes/deletes or sync changes.
- 14 connected-device native lifecycle checks with call-state readback passed: incoming caller info, answer, mute/unmute, hold/resume, contact update, end/clear, outgoing dial/connect, waiting call, ending the active call while waiting, answering the waiting call, and clearing all calls.
- Native caller name/number confirmed on the physical workstation. Headset actions observed in Sipper, including return to idle after End. Final mute transport correction passed the connected-device lifecycle test.
- Final app-originated answer, mute, unmute and end completed without a helper error or reconnect.
- Native protocol checks passed for packet framing, padding, UTF-8 boundaries and action-code decoding.
- No real PBX call or microphone test was placed during this native-protocol work.
- An existing SIP account was observed registered in the BH71 build.
- Upstream full Xcode/XCTest suite was not run: this Mac has Command Line Tools but no full Xcode installation.

## Build

From this branch or the extracted source directory:

```sh
./script/test_bh71.sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
```

The build script downloads pinned PJSIP/Opus dependencies if needed. The native headset helper has no third-party SDK dependency. It always builds the separate BH71 identity. Command Line Tools and ripgrep are required. It uses the installed macOS 26.5 SDK when available because this Mac's CLT 27 lacks the SwiftUI State macro plugin; `SIPPER_SDK_PATH` overrides the SDK. The Codex Run action calls the same script.

An explicit connected-device lifecycle test is available as:

```sh
python3 script/test_native_helper.py 'dist/Sipper BH71 Test.app/Contents/Helpers/BH71NativeBridge'
```

Run that hardware test only while Sipper is closed; it changes temporary call state on the BH71. It makes no PBX calls.

The adapter is restricted to the observed BH71 Workstation `6993:b07e`. It does not change firmware or pairing. When the native caller-ID helper is unavailable, native USB button controls remain available and the UI reports the caller-ID problem.

References: [Yealink SDK package](https://www.npmjs.com/package/@yealink_dev/yealink-node-sdk), [Genesys Yealink call-control implementation](https://github.com/purecloudlabs/softphone-vendor-headsets/blob/main/react-app/src/library/services/vendor-implementations/yealink/yealink.ts).
