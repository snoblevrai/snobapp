// Limite de charge native de macOS (« MCL », macOS 26.4+) via PowerUI.framework (privé).
// Signatures relevées par introspection du runtime Objective-C sur PowerUISmartChargeClient :
//   isMCLSupported              B16@0:8
//   availableChargeLimitsWithError:  @24@0:8^@16   → NSArray<NSNumber> (80, 85, 90, 95, 100)
//   getMCLLimitWithError:       C24@0:8^@16
//   setMCLLimit:error:          B28@0:8C16^@20      (valeurs hors liste refusées, code 4)
//   enableMCL: / disableMCL:    B24@0:8^@16
//   isMCLCurrentlyEnabled:      Q24@0:8^@16
// Fonctionne sans droits root.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include "PowerUIBridge.h"

static id client(void) {
    static id c = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW)) return;
        Class cls = objc_getClass("PowerUISmartChargeClient");
        if (!cls || ![cls instancesRespondToSelector:@selector(initWithClientName:)]) return;
        c = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], @selector(initWithClientName:), @"snobapp");
    });
    return c;
}

static BOOL responds(SEL s) { id c = client(); return c && [c respondsToSelector:s]; }

bool CSNativeLimitSupported(void) {
    if (!responds(@selector(isMCLSupported))) return false;
    return ((BOOL (*)(id, SEL))objc_msgSend)(client(), @selector(isMCLSupported));
}

int CSNativeLimitAvailable(int *values, int max) {
    if (!responds(@selector(availableChargeLimitsWithError:))) return 0;
    NSError *e = nil;
    NSArray *a = ((id (*)(id, SEL, NSError **))objc_msgSend)(client(), @selector(availableChargeLimitsWithError:), &e);
    int n = 0;
    for (id v in a) {
        if (n >= max) break;
        if ([v respondsToSelector:@selector(intValue)]) values[n++] = [v intValue];
    }
    return n;
}

int CSNativeLimitGet(void) {
    if (!responds(@selector(getMCLLimitWithError:))) return -1;
    NSError *e = nil;
    unsigned char v = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(client(), @selector(getMCLLimitWithError:), &e);
    return e ? -1 : v;
}

bool CSNativeLimitEnabled(void) {
    if (!responds(@selector(isMCLCurrentlyEnabled:))) return false;
    NSError *e = nil;
    unsigned long long v = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(client(), @selector(isMCLCurrentlyEnabled:), &e);
    return !e && v != 0;
}

bool CSNativeLimitSet(int percent) {
    if (!responds(@selector(setMCLLimit:error:))) return false;
    NSError *e = nil;
    return ((BOOL (*)(id, SEL, unsigned char, NSError **))objc_msgSend)(client(), @selector(setMCLLimit:error:), (unsigned char)percent, &e);
}

bool CSNativeLimitSetEnabled(bool enabled) {
    SEL s = enabled ? @selector(enableMCL:) : @selector(disableMCL:);
    if (!responds(s)) return false;
    NSError *e = nil;
    return ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(client(), s, &e);
}
