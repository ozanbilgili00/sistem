#include "CPrivate.h"
#include <string.h>

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct layout must match the kernel's");

enum {
    kSMCUserClientSelector = 2,
    kSMCCmdReadBytes = 5,
    kSMCCmdReadIndex = 8,
    kSMCCmdReadKeyInfo = 9,
};

io_connect_t SMCOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return IO_OBJECT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : IO_OBJECT_NULL;
}

void SMCClose(io_connect_t connection) {
    if (connection != IO_OBJECT_NULL) IOServiceClose(connection);
}

static int call(io_connect_t connection, SMCParamStruct *input, SMCParamStruct *output) {
    size_t size = sizeof(SMCParamStruct);
    kern_return_t result = IOConnectCallStructMethod(connection, kSMCUserClientSelector,
                                                     input, sizeof(SMCParamStruct), output, &size);
    if (result != KERN_SUCCESS) return -1;
    return output->result == 0 ? 0 : -2;
}

int SMCReadKey(io_connect_t connection, uint32_t key, SMCKeyInfoData *info, uint8_t *bytes) {
    SMCParamStruct input = {0}, output = {0};
    input.key = key;
    input.data8 = kSMCCmdReadKeyInfo;
    if (call(connection, &input, &output) != 0) return -1;
    *info = output.keyInfo;

    input.keyInfo = output.keyInfo;
    input.data8 = kSMCCmdReadBytes;
    memset(&output, 0, sizeof output);
    if (call(connection, &input, &output) != 0) return -1;
    memcpy(bytes, output.bytes, sizeof output.bytes);
    return 0;
}

int SMCKeyAtIndex(io_connect_t connection, uint32_t index, uint32_t *key) {
    SMCParamStruct input = {0}, output = {0};
    input.data8 = kSMCCmdReadIndex;
    input.data32 = index;
    if (call(connection, &input, &output) != 0) return -1;
    *key = output.key;
    return 0;
}

int SMCReadKeyInfo(io_connect_t connection, uint32_t key, SMCKeyInfoData *info) {
    SMCParamStruct input = {0}, output = {0};
    input.key = key;
    input.data8 = kSMCCmdReadKeyInfo;
    if (call(connection, &input, &output) != 0) return -1;
    *info = output.keyInfo;
    return 0;
}

int SMCReadBytesWithInfo(io_connect_t connection, uint32_t key, SMCKeyInfoData info, uint8_t *bytes) {
    SMCParamStruct input = {0}, output = {0};
    input.key = key;
    input.keyInfo = info;
    input.data8 = kSMCCmdReadBytes;
    if (call(connection, &input, &output) != 0) return -1;
    memcpy(bytes, output.bytes, sizeof output.bytes);
    return 0;
}
