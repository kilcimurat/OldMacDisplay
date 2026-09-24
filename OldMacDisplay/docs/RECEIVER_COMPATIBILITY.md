# Receiver compatibility: macOS Catalina 10.15 on a 2013 Intel iMac

Everything in this document was verified against the toolchain in this repo
(Xcode 26.2, Swift 6.2.3, macOS SDK 26.2) by building and inspecting the actual
Mach-O binary. Claims that could not be verified without the iMac are marked as
unverified.

## Summary

| Question | Answer |
|---|---|
| Can Xcode 26.2 still target macOS 10.15? | **Yes**, verified: `vtool -show-build` reports `minos 10.15` |
| Can it still build x86_64? | **Yes**, verified: `lipo -archs` reports `x86_64` |
| Is a separate old Xcode needed? | **No** |
| Does the Receiver need embedded runtime libraries? | **No**, as long as it stays concurrency-free |

## The three hard constraints

### 1. Deployment target 10.15, enforced by the package manifest

Both packages, `App/Package.swift` and `Shared/Package.swift`, declare
`platforms: [.macOS(.v10_15)]`. The compiler then rejects any API newer than
Catalina unless it is guarded with `@available`. This is the primary defence
against accidentally using a modern API.

The app is a single universal binary that hosts on the Apple Silicon Mac and
receives on the iMac, so the Host half cannot have its own newer deployment
target. Every Host-only type is marked `@available(macOS 13.0, *)` and
ScreenCaptureKit is weak-linked (see `App/Package.swift`).

### 2. x86_64

The 2013 iMac is Intel. The build script always builds
`--arch arm64 --arch x86_64`. A build that defaulted to the host architecture
would produce an arm64 binary that simply will not launch there.

### 3. No Swift Concurrency anywhere

`async`/`await` *compiles* for a 10.15 deployment target, but the resulting
binary weakly links `@rpath/libswift_Concurrency.dylib`, which does not exist in
Catalina's `/usr/lib/swift`. Running it requires embedding the back-deployment
copy from the toolchain into the app bundle and adding an `@loader_path` rpath.

That mechanism works, but it is one more thing that can silently break on a
machine that is slow to iterate on. The whole app therefore uses callbacks and
`DispatchQueue` throughout, and the binary links no concurrency runtime at all.
`Scripts/verify-catalina.sh` fails the build if this ever regresses.

Practical consequence: `MessageTransport`, `Heartbeat`, `NWMessageChannel`,
`ReceiverClient` and the Host's capture/encode pipeline are all callback-based.

## Why AppKit and not SwiftUI

SwiftUI exists on Catalina, but the `App` protocol and `@main` scene lifecycle
are macOS 11+. The Receiver therefore uses an explicit `main.swift` that creates
`NSApplication`, installs a programmatic menu bar (`MainMenu.swift`) and shows an
`NSWindowController`.

This also suits Phase 2: the full-screen video renderer needs direct access to a
layer-backed `NSView` (`AVSampleBufferDisplayLayer` or a `CAMetalLayer`), which
is more direct in AppKit than through SwiftUI representables.

## Verifying a build

`Scripts/verify-catalina.sh` inspects the built binary and checks:

1. `x86_64` is present
2. minimum OS is `<= 10.15`
3. `libswift_Concurrency.dylib` is **not** linked
4. every **strongly**-linked dylib exists in macOS 10.15
5. reports post-Catalina overlays that are **weakly** linked (informational)

It runs automatically as part of `./Scripts/build.sh`.

### Why the weak/strong distinction matters

The current Receiver binary weakly links two libraries that do **not** exist on
Catalina:

```
/usr/lib/swift/libswiftOSLog.dylib
/usr/lib/swift/libswiftUniformTypeIdentifiers.dylib
```

`UniformTypeIdentifiers` is macOS 11+. These are pulled in automatically by the
Swift SDK overlays, not by our code. Because they are `LC_LOAD_WEAK_DYLIB`,
dyld tolerates their absence and the app still launches — the symbols resolve to
null and are never called, since nothing in our source uses them.

Had they been strongly linked (`LC_LOAD_DYLIB`), the app would have died at
launch on the iMac with a dyld error while building and running perfectly on the
M2 Max. This is exactly the class of failure the verifier exists to catch.

The 15 strongly-linked dependencies are all Catalina-era: AppKit, Foundation,
CoreGraphics, Metal, VideoToolbox, SystemConfiguration, libSystem, libc++,
libobjc, and the matching Swift overlays.

## API choices and their availability

| API | Introduced | Used for |
|---|---|---|
| `NWBrowser`, `NWListener` | 10.15 | Bonjour discovery |
| `NWConnection`, `NWPathMonitor` | 10.14 | Transport, link-type detection |
| `os_log` / `OSLog` | 10.12 | Logging |
| `VTIsHardwareDecodeSupported` | 10.13 | Codec capability probe |
| `CGDisplayCopyDisplayMode` | 10.6 | Refresh-rate detection |
| `MTLCreateSystemDefaultDevice` | 10.11 | GPU name, future renderer |

Two deliberate avoidances:

* **`os.Logger`** is macOS 11+. `Shared/Utilities/Log.swift` wraps the older
  `OSLog` + `os_log` API instead. Output is identical in Console.app, under the
  `com.oldmacdisplay` subsystem with the same categories.
* **`NSScreen.maximumFramesPerSecond`** is macOS 12+. The Receiver reads
  `CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate` instead, and falls
  back to 60 Hz when it reports 0 — which built-in panels commonly do.

## Hardware detection is fully dynamic

Nothing about the iMac is hardcoded. `ReceiverHardwareProfile.detect()` reads
resolution and backing scale from `NSScreen`, refresh rate from CoreGraphics,
CPU/memory from sysctl, GPU from Metal, and codec support from VideoToolbox.
The 21.5" and 27" 2013 iMacs therefore negotiate different modes with no code
change.

## Unverified until the iMac is available

These need a real Catalina run and are the first things to check in Phase 2:

* **Actual launch on 10.15.** The Mach-O analysis is strong evidence but not
  proof. A dyld failure would appear immediately at launch.
* **Hardware H.264 decode.** `VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)`
  is expected to return `true` (Haswell/Iris Pro has a fixed-function decoder)
  but has only been observed on the M2 Max so far.
* **HEVC decode is expected to be `false`.** A 2013 iMac has no HEVC decode
  block. If it unexpectedly reports `true` it would be a software decoder, which
  would be far too slow — see the note in `CapabilityNegotiator.chooseCodec`.
* **Gigabit Ethernet link detection.** `PathObserver` has only been exercised on
  Wi-Fi so far; `NetworkType.ethernet` is untested on real hardware.

## Known issue: VPN and the LAN session

A full-tunnel VPN can remove the route to the peer and kill a running session
("No route to host", POSIX 65), even with the Ethernet cable untouched.

Two attempts to keep the session off the tunnel were made and **both were
reverted**, because each one broke connecting outright:

| Attempt | Result |
| --- | --- |
| `NWParameters.requiredInterface` = the NIC the Host was discovered on | `NWConnection` stalls in `.preparing` forever |
| `NWParameters.prohibitedInterfaceTypes` = every link but the chosen one | Same stall |

The stall is silent: no `waiting`, no `failed`, no error of any kind. Measured
against a running Host with all four parameter sets, an unconstrained connection
succeeds and routing picks Ethernet by itself, while a Wi-Fi-only constraint
never connects. The cause is that a resolved Bonjour endpoint carries addresses
for *all* of the peer's interfaces; a constraint that rules out the route to the
address being tried leaves the connection nothing to fall back to.

So the connection is unconstrained, and `ReceiverClient` carries a connect
watchdog that fails a connection which has not become ready in 6 seconds — the
stall is at least visible now rather than an indefinite "Connecting".

**VPN avoidance remains unsolved for the first connection.** Disconnect the
VPN before starting a session. The second (video) connection already does the
right thing: it is opened to the concrete address the control connection
resolved to (`NWMessageChannel.remoteEndpoint`), not to the service endpoint,
so it lands on the same interface without any constraint. Doing the same for
the control connection would mean resolving the Bonjour service to a concrete
address on the chosen subnet first.
