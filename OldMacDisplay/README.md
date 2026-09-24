# OldMacDisplay

Use a 2013 Intel iMac as a real extended display for an Apple Silicon Mac.

Not mirroring: the Host creates a virtual monitor that macOS extends onto, so
windows can be dragged to the right and appear on the old Mac.

**Status:** working end to end on real hardware — virtual display, capture,
H.264/HEVC encode, stream, hardware decode, full-screen render. Latency tuning
(Phase 4) is the current work.

## One app, two roles

There is a single universal `.app`. Copy the same bundle to both machines; it
works out which half of itself is usable.

```
┌─ OldMacDisplay ───────────────────────┐
│  [ Share This Mac ]  [ Use As Display ]│
└────────────────────────────────────────┘
```

* **Share This Mac** — creates the virtual display and streams it.
  Needs macOS 13+. On an older Mac the tab explains why it is unavailable.
* **Use As Display** — finds a Mac on the LAN and shows its virtual screen
  full screen. Works back to macOS 10.15.

## Layout

```
OldMacDisplay/
├── App/        the application (universal, macOS 10.15+)
│   └── Sources/
│       ├── OldMacDisplay/
│       │   ├── Shell/      app entry, tabbed window, both panes
│       │   ├── Host/       virtual display, capture, encode, serve
│       │   └── Receiver/   discover, connect, decode, render
│       └── OMDPrivateDisplay/   the only private-API code (Objective-C)
├── Shared/     protocol, messages, models, transport (+ 64 unit tests)
├── Scripts/    build.sh, verify-catalina.sh
└── docs/       VIRTUAL_DISPLAY.md, RECEIVER_COMPATIBILITY.md
```

## Build

```sh
./Scripts/build.sh          # tests, universal app, Catalina verification
./Scripts/build.sh app
./Scripts/build.sh test
```

Output: `build/OldMacDisplay.app` and `build/OldMacDisplay.zip`.

**Copy the zip, not the .app**, to the other machine. A plain copy to a USB
stick loses the executable bit and macOS then refuses to treat the bundle as an
application; the zip is made with `ditto`, which preserves it.

## Running

1. Launch on the Apple Silicon Mac. Grant **Screen Recording** when asked —
   without it there is nothing to stream, and macOS reports the denial with a
   message that does not say so.
2. Launch on the old Mac, open **Use As Display**, pick the Mac, **Connect**.
3. The stream opens in its own window. ⌃⌘F for full screen, Esc to leave.

On macOS 15+ both machines also need **Local Network** permission. When it is
denied, Bonjour discovery returns zero results with no error at all.

### Command-line flags

For diagnostics and two-machine testing:

```sh
OldMacDisplay --connect 192.168.2.2    # skip Bonjour (direct Ethernet)
OldMacDisplay --auto-connect "MacBook" # connect to the first match
OldMacDisplay --codec h264             # force a codec instead of negotiating
OldMacDisplay --resolution 1920x1080
OldMacDisplay --fps 60
OldMacDisplay --quit-after 10
```

`--connect` is not only for testing: a direct Ethernet cable between two Macs
may have no working mDNS.

## The three constraints that shape the code

The Receiver has to run on Catalina on an Intel iMac, and the same binary hosts
on an M2 Max. That forces:

1. **No Swift Concurrency anywhere.** `async`/`await` back-deploys to 10.15 only
   by embedding `libswift_Concurrency.dylib`. The whole app uses callbacks and
   GCD instead, so the binary needs no back-deployment runtime.
2. **ScreenCaptureKit is weak-linked.** It does not exist on Catalina; a strong
   link would stop the app launching there.
3. **AppKit, not SwiftUI.** The SwiftUI `App` lifecycle is macOS 11+.

`Scripts/verify-catalina.sh` checks all three against the built x86_64 slice on
every build, plus that every strongly-linked dylib existed in 10.15. It runs
automatically and fails the build.

## Protocol

Binary framing, 12-byte header. Control payloads are JSON with an explicit
`type` discriminator; video is the raw compressed bitstream, never re-encoded.

```
0  ..< 4   magic "OMDS"
4          protocol version
5          channel (control | video | audio | input)
6          flags
7          reserved
8  ..< 12  payload length, big-endian
12 ..<     payload
```

All four channels are in the wire format already, so video and audio can move to
their own connections later without a protocol break.

## Diagnostics

```sh
log stream --level debug --predicate 'subsystem == "com.oldmacdisplay"'
```

Categories: `virtual-display`, `capture`, `encoder`, `network`, `decoder`,
`renderer`, `discovery`, `audio`, `input`, `app`. Capture/encode and render
throughput are logged once a second; per-ping RTT at debug level.
