# Virtual display on macOS 26

How OldMacDisplay makes macOS believe a second monitor is attached, which
private API that needs, and what happens when Apple changes it.

## Why private API at all

There is **no public macOS API to create a virtual display**. The supported
route is a DriverKit display driver extension, which requires an entitlement
Apple grants case by case and does not hand out for hobby projects.

Every third-party virtual-display app on macOS — BetterDisplay, Duet, Luna and
the rest — uses the same four undocumented CoreGraphics classes instead. This
project does too, with the consequences spelled out below.

Consequences accepted for this project:

* **Not distributable on the Mac App Store.** Review rejects private-API use.
  The user stated App Store compatibility is not a requirement.
* **No compatibility promise.** These classes can be renamed or removed in any
  macOS release, including a point update.

## The API, verified against this machine

Everything below was read from the **live Objective-C runtime on macOS 26.5.1
(build 25F80, Apple Silicon)** by dumping `class_copyMethodList` and
`class_copyPropertyList`, not copied from an old header dump. The header dumps
circulating online are from Mojave and are no longer a reliable reference.

### `CGVirtualDisplayDescriptor` — what the fake monitor claims to be

```objc
- (instancetype)init;
@property (copy)   NSString *name;
@property          uint32_t vendorID;
@property          uint32_t productID;
@property          uint32_t serialNum;        // note: also a serialNumber property
@property          uint32_t maxPixelsWide;
@property          uint32_t maxPixelsHigh;
@property          CGSize   sizeInMillimeters;
@property          CGPoint  redPrimary;       // CIE xy
@property          CGPoint  greenPrimary;
@property          CGPoint  bluePrimary;
@property          CGPoint  whitePoint;
@property (strong) dispatch_queue_t queue;
@property (copy)   void (^terminationHandler)(id, id);
```

### `CGVirtualDisplayMode` — one resolution

```objc
- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h refreshRate:(double)hz;
- (instancetype)initWithWidth:(uint32_t)w height:(uint32_t)h refreshRate:(double)hz
             transferFunction:(uint32_t)fn;
```

### `CGVirtualDisplaySettings` — how it behaves

```objc
- (instancetype)init;
@property (strong) NSArray *modes;    // of CGVirtualDisplayMode
@property          uint32_t hiDPI;
@property          uint32_t rotation;
@property          double   refreshDeadline;
@property          BOOL     isReference;
```

### `CGVirtualDisplay` — the display itself

```objc
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
```

### Call order

1. `CGVirtualDisplayDescriptor` → set identity, pixel limits, physical size,
   colour primaries, queue, termination handler
2. `CGVirtualDisplay initWithDescriptor:`
3. `CGVirtualDisplaySettings` → set `modes` (one `CGVirtualDisplayMode`), `hiDPI`
4. `applySettings:` — returns `NO` if macOS rejects the configuration
5. Read `displayID`, then poll `CGGetActiveDisplayList` until it appears

## Verified behaviour on macOS 26.5.1

A 1920×1080 @ 60 Hz display was created and removed successfully:

```
BEFORE: 1 active display     id=1  1728x1117  main=yes
CREATED displayID=10
AFTER:  2 active displays    id=1  1728x1117  main=yes
                             id=10 1920x1080  main=no
bounds: origin=(1728,0) size=1920x1080
AFTER REMOVE: 1 active display
```

Three things this confirms:

* macOS treats it as a **real second display**, not a mirror (`main=no`)
* it is **automatically placed to the right** of the main display
  (`origin.x` = main display width), which is exactly the arrangement wanted
* releasing the object **removes it cleanly**

The `displayID` is an ordinary `CGDirectDisplayID`, so ScreenCaptureKit,
`CGDisplayBounds` and System Settings › Displays all accept it.

## Traps

These are the ones that bite; each shaped the implementation.

### Never change the display's mode

After `CGDisplaySetDisplayMode` or `CGBeginDisplayConfiguration` touches the
virtual display, **releasing the object no longer removes it** — it stays on the
desktop until the process exits.

`CGVirtualDisplayProvider` therefore publishes exactly **one** mode and never
changes it. A resolution change destroys the display and creates a new one.

### macOS remembers the monitor identity

Arrangement and colour settings are remembered per
`(vendorID, productID, serialNumber)`. A random identity per launch makes macOS
treat each run as a new monitor and forget the arrangement, so these are fixed
constants (`0x4F4D4400` = "OMD\0", product 1, serial 1) in
`CGVirtualDisplayProvider.Identity`.

### Creation and removal are asynchronous

The object exists before macOS lists the display, and removal can lag by up to
~2 seconds. The provider polls `CGGetActiveDisplayList` after creation and
refuses to hand back a display that never appeared; capture therefore never
starts against a display that is not there yet.

### The creating process cannot read its own display's modes

`CGDisplayCopyDisplayMode` returns NULL and `CGDisplayCopyAllDisplayModes`
returns nothing **for a display this process created**. Other processes see it
normally. Nothing in the Host relies on reading those back — the mode is known
because we chose it.

## Isolation and failure behaviour

All private-API contact is in **one Objective-C target**,
`Host/Sources/OMDPrivateDisplay`, behind the `VirtualDisplayProvider` protocol.
No Swift file names a private class, and nothing above the protocol knows how
the display is made.

Two deliberate safety properties:

* **Nothing is linked.** Classes are resolved with `NSClassFromString` and every
  selector is checked with `instancesRespondToSelector:`. No
  `_OBJC_CLASS_$_CGVirtualDisplay*` symbol appears in the binary, so the app
  still launches if CoreGraphics drops the classes.
* **Failure is reported, not fatal.** `+isAvailable` returns NO and
  `+availabilityReport` names the exact missing class or selector, which reaches
  the Host UI as an error rather than a crash.

The selector list checked at runtime is in `OMDRequiredSelectors()`.

## If a future macOS breaks this

Expected symptom: `availabilityReport` naming a missing class or selector, and
the Host refusing to start a session with that message.

Options in order of preference:

1. Re-dump the runtime (the program used is in this document's history) and
   adjust the selector list — most breakages are renames.
2. Fall back to capturing the physical main display, i.e. mirroring. Degraded
   but working; the whole capture/encode/stream path is unchanged.
3. DriverKit display extension, if Apple ever grants the entitlement.

## Sources

Reverse-engineering references consulted (not copied):

- [go-macos/virtualdisplay](https://github.com/go-macos/virtualdisplay) — the
  most current documentation of the API's behaviour, tested on macOS 26.6.2
- [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror) — CGVirtualDisplay
  used for HiDPI mirroring
- [Chr0nicT/macOS-Headers](https://github.com/Chr0nicT/macOS-Headers-10.14.6-Mojave/blob/master/Frameworks/CoreGraphics/1265.9/CGVirtualDisplaySettings.h)
  — Mojave-era header dump, useful for history, stale for current selectors
