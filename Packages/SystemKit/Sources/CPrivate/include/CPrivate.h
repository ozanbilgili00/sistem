// Declarations for undocumented macOS APIs used by SystemKit. Everything here is
// reverse-engineered and can change with an OS update — callers must treat every
// result as optional.

#ifndef CPRIVATE_H
#define CPRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// MARK: - HID sensor events (IOKit, exported but not in public headers)

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client, CFDictionaryRef _Nonnull matching);
IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service, int64_t type, int32_t options, int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(IOHIDEventRef _Nonnull event, int32_t field);

/// Event types for IOHIDServiceClientCopyEvent. A value field is `type << 16`.
enum {
    kSistemHIDEventTypeTemperature = 15,
    kSistemHIDEventTypePower = 25,
};

// MARK: - SMC (AppleSMC user client)

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

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
} SMCParamStruct;

/// Opens the AppleSMC user client. Returns 0 (IO_OBJECT_NULL) on failure.
io_connect_t SMCOpen(void);
void SMCClose(io_connect_t connection);

/// Reads one key. Returns 0 on success; fills `info` and up to 32 bytes.
int SMCReadKey(io_connect_t connection, uint32_t key, SMCKeyInfoData *_Nonnull info, uint8_t *_Nonnull bytes);

/// The key stored at `index` (0..<#KEY). Returns 0 on success.
int SMCKeyAtIndex(io_connect_t connection, uint32_t index, uint32_t *_Nonnull key);

#endif
