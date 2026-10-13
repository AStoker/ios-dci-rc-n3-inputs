# Running the probe on your iPhone (first time)

## One-time Mac setup

1. Point the command-line tools at full Xcode (right now they point at the standalone Command Line Tools):
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
   This affects `xcodebuild`, `swift test` and Claude's Simulator integration. It doesn't change Xcode.app itself.
2. Open the project: double-click `RCN3Probe.xcodeproj` (or `open RCN3Probe.xcodeproj`).
3. **Xcode › Settings › Accounts**: add your Apple ID if it isn't listed.

## Signing (what it is and how to set it)

iOS only runs code that is **signed**, meaning cryptographically stamped with a certificate tied to your Apple ID. A **provisioning profile** is the permission slip that says "this app id, signed by this team, may run on these devices". Web analogy: a TLS certificate plus an allow-list of the browsers allowed to load the site. Xcode creates and renews both for you when automatic signing is on.

1. Click the blue **RCN3Probe** project at the top of the navigator, select the **RCN3Probe** target, then open the **Signing & Capabilities** tab.
2. Leave **Automatically manage signing** on. Set **Team** to your team (a personal Apple ID "Personal Team" works).
3. If Xcode says the bundle id `com.astoker.rcn3probe` is unavailable, change it to anything unique, e.g. `com.astoker.rcn3probe2`.

Notes:
- External Accessory needs **no entitlement** for development. The `UISupportedExternalAccessoryProtocols` list in `RCN3Probe/Info.plist` is all it takes. Apple's MFi program only matters for App Store release.
- A free Personal Team build expires after 7 days. Just run it again from Xcode. Paid-program builds last a year.

## iPhone setup

1. **Developer Mode**: Settings › Privacy & Security › Developer Mode › On, then restart. (iOS asks for this before it will run dev builds.)
2. Connect the iPhone to the Mac with a cable and unlock it. Tap **Trust** if asked.
3. **Wireless debugging**: the iPhone has one USB-C port and the remote needs it, so you'll install and launch over Wi-Fi. Once the phone has been paired over a cable and is on the same Wi-Fi as the Mac, Xcode shows it with a network icon in the run-destination menu. If it doesn't, open Window › Devices and Simulators, select the phone, and enable **Connect via network**.

## Run

1. In the toolbar's run-destination menu pick **Andy Stoker's iPhone**.
2. Press **⌘R** (Product › Run). The first build compiles RCKit, then installs and launches the app.
3. If the phone says **Untrusted Developer** (Personal Team only): Settings › General › VPN & Device Management › your Apple ID › Trust. Then launch again.

After that the app stays installed and you can open it from the Home Screen like any other app. Everything the probe sees is logged inside the app, so you don't need Xcode attached while testing with the remote.

Launch arguments (Product › Scheme › Edit Scheme › Run › Arguments):
- `-initialTab 2` opens on a given tab (0 Input, 1 Overview, 2 Streams, 3 DUML, 4 Log).
- `-replay <recording name>` starts replaying a recording from Documents/Recordings at launch (demo without the remote).

## Tests

`⌘U` in Xcode runs both test targets: RCKitTests (DUML codec, sample assembly, stick modes, recording) and RCKitProbeTests (analyzer). From Terminal: `cd RCKit && swift test`.
