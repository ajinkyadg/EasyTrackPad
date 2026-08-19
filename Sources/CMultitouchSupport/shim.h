#ifndef CMultitouchSupport_h
#define CMultitouchSupport_h

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

/// Undocumented private-framework declarations for
/// /System/Library/PrivateFrameworks/MultitouchSupport.framework.
///
/// There are no official headers for this framework — Apple has never
/// published one. This layout is the one consistently reverse-engineered
/// and reused across the open-source multitouch-utility ecosystem (the
/// same struct shape BetterTouchTool-alikes have relied on for years).
/// It can change or vanish on any macOS update without notice; that's the
/// accepted trade-off for finger-count-aware gestures (see README).

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;      // 1 not tracking, 2 starting, 3 hover, 4 touching, 5-7 releasing
    int32_t fingerId;
    int32_t handId;
    MTVector normalizedVector; // position/velocity normalized to 0...1 over the trackpad surface
    float size;
    int32_t zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int32_t zero2[2];
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;

typedef int (*MTContactCallbackFunction)(MTDeviceRef device, MTTouch *touches, int32_t numTouches, double timestamp, int32_t frame);

MTDeviceRef MTDeviceCreateDefault(void);
/// Creates a device bound to a specific `AppleMultitouchDevice`-family
/// IOService (confirmed via disassembly: internally checks
/// IOObjectConformsTo against "AppleMultitouchSPI",
/// "AppleUSBMultitouchDriver", "AppleMultitouchDevice", and
/// "AppleMultitouchDummy" — passing a service of any other class returns
/// NULL). Callers find that service themselves via the fully public
/// IOKit APIs (`IOServiceGetMatchingServices(IOServiceMatching(
/// "AppleMultitouchDevice"))`) — this is the one MultitouchSupport call
/// site itself that's private, everything upstream of it isn't. This is
/// the fix for a Magic Mouse specifically: its multitouch shell runs as
/// its own `AppleMultitouchDevice` kernel-driver instance (confirmed via
/// `ioreg`, Transport=Bluetooth, Product="Magic Mouse") distinct from the
/// trackpad's — `MTDeviceCreateList()`/`MTDeviceIsBuiltIn()` never
/// reliably surfaced or delivered frames for it, but targeting its exact
/// IOService directly via this call does.
MTDeviceRef MTDeviceCreateFromService(io_service_t service);
void MTDeviceRelease(MTDeviceRef device);
void MTRegisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTUnregisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
void MTDeviceStart(MTDeviceRef device, int32_t unknown);
void MTDeviceStop(MTDeviceRef device);

#endif /* CMultitouchSupport_h */
