// Liaison dynamique avec le framework privé MultitouchSupport.
// API utilisée : MTDeviceCreateList, MTRegisterContactFrameCallback, MTDeviceStart,
// MTDeviceStop, MTDeviceRelease, MTUnregisterContactFrameCallback (cf. le projet open source
// MiddleClick). On passe par dlopen car le SDK ne fournit pas de .tbd pour les frameworks privés.

#include "CMultitouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdatomic.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;

typedef struct {
    int frame;
    double timestamp;
    int pathIndex;
    int state;
    int fingerID;
    int handID;
    MTReadout normalized;
    float zTotal;
    int field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTReadout absolute;
    int field14;
    int field15;
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);
static void (*pMTDeviceStop)(MTDeviceRef);
static void (*pMTDeviceRelease)(MTDeviceRef);

static _Atomic(CSTouchFrameHandler) gHandler = NULL;
static _Atomic int gPositionLimit = 3;
static CFArrayRef gDevices = NULL;

static int contactCallback(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    (void)device; (void)timestamp; (void)frame;
    CSTouchFrameHandler handler = atomic_load(&gHandler);
    if (!handler) return 0;

    int limit = atomic_load(&gPositionLimit);
    int n = count < limit ? count : limit;
    float sx = 0, sy = 0;
    for (int i = 0; i < n; i++) {
        sx += touches[i].normalized.pos.x;
        sy += touches[i].normalized.pos.y;
    }
    handler(count, sx, sy);
    return 0;
}

bool CSMultitouchLoad(void) {
    static bool loaded = false;
    if (loaded) return true;
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!h) return false;
    pMTDeviceCreateList = dlsym(h, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback = dlsym(h, "MTRegisterContactFrameCallback");
    pMTUnregisterContactFrameCallback = dlsym(h, "MTUnregisterContactFrameCallback");
    pMTDeviceStart = dlsym(h, "MTDeviceStart");
    pMTDeviceStop = dlsym(h, "MTDeviceStop");
    pMTDeviceRelease = dlsym(h, "MTDeviceRelease");
    loaded = pMTDeviceCreateList && pMTRegisterContactFrameCallback && pMTUnregisterContactFrameCallback
          && pMTDeviceStart && pMTDeviceStop && pMTDeviceRelease;
    return loaded;
}

void CSMultitouchSetHandler(CSTouchFrameHandler handler) { atomic_store(&gHandler, handler); }

void CSMultitouchSetPositionLimit(int limit) { atomic_store(&gPositionLimit, limit > 0 ? limit : 1); }

int CSMultitouchStart(void) {
    if (!CSMultitouchLoad()) return 0;
    CSMultitouchStop();
    gDevices = pMTDeviceCreateList();
    if (!gDevices) return 0;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pMTRegisterContactFrameCallback(dev, contactCallback);
        pMTDeviceStart(dev, 0);
    }
    return (int)count;
}

void CSMultitouchStop(void) {
    if (!gDevices) return;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pMTUnregisterContactFrameCallback(dev, contactCallback);
        pMTDeviceStop(dev);
        pMTDeviceRelease(dev);
    }
    // Chaque appareil est libéré via MTDeviceRelease ; la liste elle-même
    // n'est pas relâchée pour éviter une double libération des appareils qu'elle contient.
    gDevices = NULL;
}
