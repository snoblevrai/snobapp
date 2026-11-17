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
static _Atomic bool gEnabled = true;
static _Atomic int gFingers = 3;
static _Atomic bool gAllowMore = false;
static CFArrayRef gDevices = NULL;

// État du filtre : uniquement touché par le thread MultitouchSupport.
static int gLastCount = 0;
static float gLastX = 0, gLastY = 0;

static int contactCallback(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    (void)device; (void)timestamp; (void)frame;
    if (!atomic_load_explicit(&gEnabled, memory_order_relaxed)) return 0;
    CSTouchFrameHandler handler = atomic_load_explicit(&gHandler, memory_order_relaxed);
    if (!handler) return 0;

    int fingers = atomic_load_explicit(&gFingers, memory_order_relaxed);
    bool allowMore = atomic_load_explicit(&gAllowMore, memory_order_relaxed);
    bool matches = allowMore ? count >= fingers : count == fingers;

    float sx = 0, sy = 0;
    if (matches) {
        for (int i = 0; i < fingers && i < count; i++) {
            sx += touches[i].normalized.pos.x;
            sy += touches[i].normalized.pos.y;
        }
    }
    if (count != gLastCount) {
        // Transition : on transmet la nouvelle somme et la dernière somme « correspondante ».
        handler(count, sx, sy, gLastX, gLastY);
        gLastCount = count;
    }
    if (matches) { gLastX = sx; gLastY = sy; }
    return 0;
}

void CSMultitouchConfigure(bool enabled, int fingers, bool allowMore) {
    atomic_store(&gFingers, fingers > 0 ? fingers : 1);
    atomic_store(&gAllowMore, allowMore);
    atomic_store(&gEnabled, enabled);
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


int CSMultitouchStart(void) {
    if (!CSMultitouchLoad()) return 0;
    CSMultitouchStop();
    gLastCount = 0;
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
