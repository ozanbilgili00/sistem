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

/// Key metadata (type, size, attributes) alone: one call. Constant per key, so callers
/// cache it and use ``SMCReadBytesWithInfo`` afterwards.
int SMCReadKeyInfo(io_connect_t connection, uint32_t key, SMCKeyInfoData *_Nonnull info);

/// Reads a key whose `info` is already known: one IOKit call instead of two. Read-only.
int SMCReadBytesWithInfo(io_connect_t connection, uint32_t key, SMCKeyInfoData info, uint8_t *_Nonnull bytes);

/// The key stored at `index` (0..<#KEY). Returns 0 on success.
int SMCKeyAtIndex(io_connect_t connection, uint32_t index, uint32_t *_Nonnull key);

// MARK: - NVMe SMART (public IOKit header, plain C wrapper)

/// The fields of the NVMe SMART / Health log page that the app shows. Counters are
/// the low 64 bits of the log page's 128-bit values.
typedef struct {
    uint8_t criticalWarning;
    uint16_t temperatureKelvin;
    uint8_t availableSpare, availableSpareThreshold, percentageUsed;
    uint64_t dataUnitsRead, dataUnitsWritten;  // thousands of 512-byte blocks
    uint64_t hostReadCommands, hostWriteCommands;
    uint64_t controllerBusyMinutes, powerCycles, powerOnHours, unsafeShutdowns, mediaErrors;
} SistemNVMeHealth;

/// Opens the SMART user client of the first service that publishes "NVMe SMART Capable".
/// The handle stays valid until `SistemNVMeClose`; NULL when none works. No root is
/// needed for the internal SSD of this Mac (measured 2026-10-08).
void *_Nullable SistemNVMeOpen(void);
/// 0 on success.
int SistemNVMeRead(void *_Nonnull handle, SistemNVMeHealth *_Nonnull out);
void SistemNVMeClose(void *_Nullable handle);


// MARK: - Display: DDC over IOAVService, internal brightness (private, Apple Silicon)

/// One external display port's DDC channel: the registry ID of its `DCPAVServiceProxy` and the
/// `dispextN` endpoint it hangs under (the key that ties it to a display).
typedef struct {
    uint64_t registryID;
    char port[16];
} SistemAVProxy;

/// What a connected external display told the system about itself: the `dispextN` port, and
/// the manufacturer / product numbers from its EDID UUID (the same numbers CoreGraphics reports
/// as vendor and model). No serial number is read.
typedef struct {
    char port[16];
    uint16_t vendor, product;
} SistemAVHint;

/// Both listings return the number of entries written (at most `capacity`). Read-only.
int SistemAVProxies(SistemAVProxy *_Nonnull out, int capacity);
int SistemAVHints(SistemAVHint *_Nonnull out, int capacity);

/// Opens the IOAVService for a proxy registry ID. NULL when it is gone or refuses. Close with `SistemAVClose`.
void *_Nullable SistemAVOpen(uint64_t registryID);
void SistemAVClose(void *_Nullable handle);
/// 0 on success. Plain I2C transfers; the caller frames DDC/CI.
int SistemAVRead(void *_Nonnull handle, uint32_t chip, uint32_t offset, uint8_t *_Nonnull buffer, uint32_t length);
int SistemAVWrite(void *_Nonnull handle, uint32_t chip, uint32_t offset, const uint8_t *_Nonnull buffer, uint32_t length);

/// Brightness of the built-in display (0...1) through DisplayServices. Returns 0 on success,
/// non-zero for displays that have no such control. Read-only: nothing here ever sets it.
int SistemInternalBrightness(uint32_t displayID, float *_Nonnull out);

#endif
