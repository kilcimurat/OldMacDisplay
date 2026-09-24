# OldMacDisplay

Use a 2013 Intel iMac as a real extended display for an Apple Silicon Mac.

Not mirroring: the Host creates a virtual monitor that macOS extends onto, so
windows can be dragged to the right and appear on the old Mac.

**Status:** working end to end on real hardware — virtual display, capture,
H.264/HEVC encode, stream, hardware decode, full-screen render. Latency tuning
(Phase 4) is the current work; see "Latency design" below for what is in.

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
├── Shared/     protocol, messages, models, transport (+ 100 unit tests)
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

## Latency design

Everything on the frame path is built around one rule: never let a backlog
form, because on this link lag accumulates rather than recovering.

* **Two TCP connections per session.** Control (handshake, heartbeat, keyframe
  requests, cursor) and video are separate, so a ping or an IDR request is
  never stuck behind a 300 KB keyframe. The Receiver opens the second
  connection to the address the first one resolved to and binds it with the
  session token the Host issued in its `hello`. If the second connection is
  refused or drops, video falls back to the control connection.
* **Exact-length socket reads, no copies.** The transport reads a 12-byte
  header, then exactly the payload, and hands that buffer to CoreMedia. The
  encoder's output is sent as header + bitstream in one scatter-gather batch;
  the bitstream `Data` points into VideoToolbox's block buffer.
* **No main-thread hop for frames.** Decoded sample buffers go from the network
  queue straight to `AVSampleBufferDisplayLayer`, which is thread-safe for it.
* **The cursor is not in the video.** ScreenCaptureKit captures without the
  pointer; the Host samples its position at the frame rate and sends it on the
  control connection, with the cursor image only when its shape changes. A
  still desktop with a moving mouse costs nothing on the wire.
* **Long GOP, keyframes on demand.** TCP loses nothing, so periodic IDRs only
  cost bitrate. The keyframe interval is 30 s and every path that can
  desynchronise the decoder (a drop on either side, a late join, a reconnect,
  a carrier switch) explicitly asks for one, with parameter sets attached.
* **Adaptive bitrate from the Receiver's view.** Once a second the Receiver
  reports displayed fps, its renderer's drop ratio and the worst queueing
  excess it measured (how much later than schedule frames arrived, which needs
  no clock sync). `BitrateController` backs the encoder off by 30% on any of
  those, or on Host-side drops or a high RTT, and recovers 15% at a time after
  three clean seconds and a 5 s hold.
* **Capture-to-screen latency is measured, not guessed.** Each pong carries the
  responder's clock; `ClockOffsetEstimator` takes the minimum-RTT sample to
  align the two clocks, and the Receiver reports the true capture-to-enqueue
  latency, shown in both UIs.

## Protocol

Protocol version 2. Binary framing, 12-byte header. Control payloads are JSON
with an explicit `type` discriminator; video is the raw compressed bitstream,
never re-encoded.

```
0  ..< 4   magic "OMDS"
4          protocol version
5          channel (control | video | audio | input)
6          flags
7          reserved
8  ..< 12  payload length, big-endian
12 ..<     payload
```

All four channels are in the wire format. Video already travels on its own
connection (bound with `attachVideo`); audio and input can follow the same
pattern without a protocol break.

## Diagnostics

```sh
log stream --level debug --predicate 'subsystem == "com.oldmacdisplay"'
```

Categories: `virtual-display`, `capture`, `encoder`, `network`, `decoder`,
`renderer`, `discovery`, `audio`, `input`, `app`. Capture/encode and render
throughput are logged once a second; per-ping RTT at debug level.
