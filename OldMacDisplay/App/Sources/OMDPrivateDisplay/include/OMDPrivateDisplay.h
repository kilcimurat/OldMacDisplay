#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// The ONLY place in this project that touches private CoreGraphics API.
///
/// macOS has no public way to create a virtual display; the public route is a
/// DriverKit extension requiring an Apple-granted entitlement. Every
/// third-party virtual-display app uses these four undocumented CoreGraphics
/// classes instead:
///
///   CGVirtualDisplayDescriptor, CGVirtualDisplaySettings,
///   CGVirtualDisplayMode, CGVirtualDisplay
///
/// See docs/VIRTUAL_DISPLAY.md for the full API surface, how it was verified,
/// and the breakage risk. Nothing here is covered by any Apple compatibility
/// promise: these classes may be renamed or removed in any macOS release,
/// including a point update.
///
/// Every class and selector is looked up by name at runtime, so a change on a
/// future macOS surfaces as `+isAvailable` returning NO rather than a crash.
/// No private symbol is referenced at link time.

extern NSString * const OMDVirtualDisplayErrorDomain;

typedef NS_ENUM(NSInteger, OMDVirtualDisplayErrorCode) {
    OMDVirtualDisplayErrorUnavailable = 1,   // classes/selectors missing
    OMDVirtualDisplayErrorAllocFailed = 2,
    OMDVirtualDisplayErrorSettingsRejected = 3, // applySettings: returned NO
    OMDVirtualDisplayErrorNoDisplayID = 4,
};

/// Owns one live virtual display. Releasing it removes the display.
@interface OMDVirtualDisplayHandle : NSObject
/// The `CGDirectDisplayID` macOS assigned. This is the handle that
/// ScreenCaptureKit and the CoreGraphics display APIs accept.
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) double refreshRate;
/// Removes the display. Idempotent. Removal is asynchronous in macOS: the
/// display can remain listed for up to ~2 seconds afterwards.
- (void)invalidate;
@end

@interface OMDVirtualDisplayBridge : NSObject

/// YES only if all four classes and every selector this bridge sends exist.
/// Check before calling `create…`; it is the runtime guard against a future
/// macOS changing the API.
+ (BOOL)isAvailable;

/// Human-readable report of what was found or missing, for diagnostics.
+ (NSString *)availabilityReport;

/// Creates a virtual display and waits for it to appear in the active display
/// list. Returns nil and populates `error` on failure.
///
/// `vendorID`/`productID`/`serialNumber` must be stable across launches:
/// macOS remembers per-monitor settings keyed on that triple, so a random
/// identity each run makes the display reappear with the wrong arrangement.
+ (nullable OMDVirtualDisplayHandle *)createDisplayWithName:(NSString *)name
                                                      width:(uint32_t)width
                                                     height:(uint32_t)height
                                                refreshRate:(double)refreshRate
                                                      hiDPI:(BOOL)hiDPI
                                                   vendorID:(uint32_t)vendorID
                                                  productID:(uint32_t)productID
                                               serialNumber:(uint32_t)serialNumber
                                                      error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
