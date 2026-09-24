#import "OMDPrivateDisplay.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSString * const OMDVirtualDisplayErrorDomain = @"com.oldmacdisplay.virtualdisplay";

#pragma mark - Private API surface
//
// Declared, never linked. Instances come from NSClassFromString, so no
// _OBJC_CLASS_$_CGVirtualDisplay* symbol is referenced at link time and the
// binary loads fine even if CoreGraphics drops these classes entirely.
//
// Verified against macOS 26.5.1 (build 25F80) by dumping the live Objective-C
// runtime. See docs/VIRTUAL_DISPLAY.md.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic) uint32_t rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

#pragma mark - Availability

/// Selectors this bridge actually sends, checked one by one so a partial API
/// change is reported precisely rather than as a generic failure.
static NSDictionary<NSString *, NSArray<NSString *> *> *OMDRequiredSelectors(void) {
    return @{
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplayDescriptor": @[
            @"setName:", @"setVendorID:", @"setProductID:", @"setSerialNum:",
            @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setSizeInMillimeters:",
            @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:",
            @"setWhitePoint:", @"setQueue:", @"setTerminationHandler:"
        ],
        @"CGVirtualDisplaySettings": @[@"setModes:", @"setHiDPI:", @"setRotation:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"],
    };
}

static NSArray<NSString *> *OMDMissingSymbols(void) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSDictionary *required = OMDRequiredSelectors();

    for (NSString *className in required) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            [missing addObject:[NSString stringWithFormat:@"class %@", className]];
            continue;
        }
        for (NSString *selectorName in required[className]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![cls instancesRespondToSelector:selector]) {
                [missing addObject:[NSString stringWithFormat:@"-[%@ %@]", className, selectorName]];
            }
        }
    }
    return missing;
}

#pragma mark - Handle

@interface OMDVirtualDisplayHandle ()
@property (nonatomic, strong, nullable) CGVirtualDisplay *display;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
- (instancetype)initWithDisplay:(CGVirtualDisplay *)display
                          queue:(dispatch_queue_t)queue
                      displayID:(CGDirectDisplayID)displayID
                           name:(NSString *)name
                          width:(uint32_t)width
                         height:(uint32_t)height
                    refreshRate:(double)refreshRate;
@end

@implementation OMDVirtualDisplayHandle {
    CGDirectDisplayID _displayID;
    NSString *_name;
    uint32_t _width;
    uint32_t _height;
    double _refreshRate;
}

@synthesize displayID = _displayID, name = _name, width = _width,
            height = _height, refreshRate = _refreshRate;

- (instancetype)initWithDisplay:(CGVirtualDisplay *)display
                          queue:(dispatch_queue_t)queue
                      displayID:(CGDirectDisplayID)displayID
                           name:(NSString *)name
                          width:(uint32_t)width
                         height:(uint32_t)height
                    refreshRate:(double)refreshRate {
    self = [super init];
    if (self) {
        _display = display;
        _queue = queue;
        _displayID = displayID;
        _name = [name copy];
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}

- (void)invalidate {
    // Releasing the CGVirtualDisplay is what removes it. This only holds
    // because we never call CGDisplaySetDisplayMode on it: after a mode change
    // macOS keeps the display alive until the process exits.
    self.display = nil;
    self.queue = nil;
}

- (void)dealloc {
    [self invalidate];
}
@end

#pragma mark - Bridge

@implementation OMDVirtualDisplayBridge

+ (BOOL)isAvailable {
    return OMDMissingSymbols().count == 0;
}

+ (NSString *)availabilityReport {
    NSArray<NSString *> *missing = OMDMissingSymbols();
    if (missing.count == 0) {
        return @"CGVirtualDisplay private API present (4 classes, all selectors).";
    }
    return [NSString stringWithFormat:@"CGVirtualDisplay private API incomplete; missing: %@",
            [missing componentsJoinedByString:@", "]];
}

+ (nullable OMDVirtualDisplayHandle *)createDisplayWithName:(NSString *)name
                                                      width:(uint32_t)width
                                                     height:(uint32_t)height
                                                refreshRate:(double)refreshRate
                                                      hiDPI:(BOOL)hiDPI
                                                   vendorID:(uint32_t)vendorID
                                                  productID:(uint32_t)productID
                                               serialNumber:(uint32_t)serialNumber
                                                      error:(NSError **)error {
    NSArray<NSString *> *missing = OMDMissingSymbols();
    if (missing.count > 0) {
        if (error) {
            *error = [NSError errorWithDomain:OMDVirtualDisplayErrorDomain
                                         code:OMDVirtualDisplayErrorUnavailable
                                     userInfo:@{NSLocalizedDescriptionKey: [self availabilityReport]}];
        }
        return nil;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass   = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass       = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass    = NSClassFromString(@"CGVirtualDisplay");

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    if (!descriptor) {
        if (error) {
            *error = [NSError errorWithDomain:OMDVirtualDisplayErrorDomain
                                         code:OMDVirtualDisplayErrorAllocFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate CGVirtualDisplayDescriptor."}];
        }
        return nil;
    }

    descriptor.name = name;
    descriptor.vendorID = vendorID;
    descriptor.productID = productID;
    descriptor.serialNum = serialNumber;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;

    // Physical size drives the default "Looks like" scaling macOS offers.
    // ~109 ppi matches a typical desktop panel and keeps text at a sane size.
    const double ppi = 109.0;
    descriptor.sizeInMillimeters = CGSizeMake((double)width / ppi * 25.4,
                                              (double)height / ppi * 25.4);

    // sRGB primaries and D65 white. Without these macOS has no colour
    // information for the display and can pick an odd default profile.
    descriptor.redPrimary   = CGPointMake(0.640, 0.330);
    descriptor.greenPrimary = CGPointMake(0.300, 0.600);
    descriptor.bluePrimary  = CGPointMake(0.150, 0.060);
    descriptor.whitePoint   = CGPointMake(0.3127, 0.3290);

    dispatch_queue_t queue = dispatch_queue_create("com.oldmacdisplay.virtualdisplay",
                                                   DISPATCH_QUEUE_SERIAL);
    descriptor.queue = queue;
    descriptor.terminationHandler = ^(id sender, id info) {
        // macOS tore the display down on its own (log out, GPU change, ...).
        NSLog(@"[OldMacDisplay] virtual display terminated by the system");
    };

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        if (error) {
            *error = [NSError errorWithDomain:OMDVirtualDisplayErrorDomain
                                         code:OMDVirtualDisplayErrorAllocFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not allocate CGVirtualDisplay."}];
        }
        return nil;
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width
                                                          height:height
                                                     refreshRate:refreshRate];
    // Only one mode is offered: macOS always runs the first entry, and adding
    // more invites a mode change, which would make the display un-removable.
    settings.modes = @[mode];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.rotation = 0;

    if (![display applySettings:settings]) {
        if (error) {
            *error = [NSError errorWithDomain:OMDVirtualDisplayErrorDomain
                                         code:OMDVirtualDisplayErrorSettingsRejected
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                     @"macOS rejected the virtual display settings (%ux%u @ %.0f Hz).",
                                                     width, height, refreshRate]}];
        }
        return nil;
    }

    CGDirectDisplayID displayID = display.displayID;
    if (displayID == 0) {
        if (error) {
            *error = [NSError errorWithDomain:OMDVirtualDisplayErrorDomain
                                         code:OMDVirtualDisplayErrorNoDisplayID
                                     userInfo:@{NSLocalizedDescriptionKey: @"Virtual display was created but macOS assigned no display ID."}];
        }
        return nil;
    }

    return [[OMDVirtualDisplayHandle alloc] initWithDisplay:display
                                                      queue:queue
                                                  displayID:displayID
                                                       name:name
                                                      width:width
                                                     height:height
                                                refreshRate:refreshRate];
}
@end
