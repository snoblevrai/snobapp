// Protocole classique du user client AppleSMC (sélecteur 2 = kSMCHandleYPCEvent ;
// commandes kSMCReadKey / kSMCWriteKey / kSMCGetKeyInfo), cf. smcFanControl.

#include "CSMC.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

static io_connect_t gConn = 0;

static uint32_t fourCC(const char *k) {
    return ((uint32_t)k[0] << 24) | ((uint32_t)k[1] << 16) | ((uint32_t)k[2] << 8) | (uint32_t)k[3];
}

static kern_return_t call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(gConn, kSMCHandleYPCEvent, in, sizeof(SMCParam), out, &outSize);
}

bool CSSMCOpen(void) {
    if (gConn) return true;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &gConn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { gConn = 0; return false; }
    return true;
}

void CSSMCClose(void) {
    if (gConn) { IOServiceClose(gConn); gConn = 0; }
}

static bool keyInfo(const char *key, SMCKeyInfoData *info) {
    SMCParam in = {0}, out = {0};
    in.key = fourCC(key);
    in.data8 = kSMCGetKeyInfo;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return false;
    *info = out.keyInfo;
    return true;
}

int CSSMCRead(const char *key, uint8_t *bytes, uint32_t *dataType) {
    if (!CSSMCOpen()) return -1;
    SMCKeyInfoData info;
    if (!keyInfo(key, &info)) return -1;
    SMCParam in = {0}, out = {0};
    in.key = fourCC(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    uint32_t n = info.dataSize > 32 ? 32 : info.dataSize;
    memcpy(bytes, out.bytes, n);
    if (dataType) *dataType = info.dataType;
    return (int)n;
}

int CSSMCWrite(const char *key, const uint8_t *bytes, uint32_t size) {
    if (!CSSMCOpen()) return -1;
    SMCKeyInfoData info;
    if (!keyInfo(key, &info)) return -2;
    if (info.dataSize != size) return -3;
    SMCParam in = {0}, out = {0};
    in.key = fourCC(key);
    in.data8 = kSMCWriteKey;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    kern_return_t kr = call(&in, &out);
    if (kr != KERN_SUCCESS) return (int)kr;
    return out.result;
}
