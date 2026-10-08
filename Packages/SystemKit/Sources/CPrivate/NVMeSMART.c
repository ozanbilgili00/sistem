#include "CPrivate.h"
#include <string.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

typedef IONVMeSMARTInterface **SmartHandle;

void *SistemNVMeOpen(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOService");
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(properties, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);
    CFDictionarySetValue(match, CFSTR("IOPropertyMatch"), properties);
    CFRelease(properties);
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) != KERN_SUCCESS) return NULL;
    SmartHandle result = NULL;
    io_service_t service;
    while (result == NULL && (service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS && plugin) {
            SmartHandle smart = NULL;
            if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart) == S_OK && smart) {
                result = smart;
            }
            (*plugin)->Release(plugin);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return result;
}

int SistemNVMeRead(void *handle, SistemNVMeHealth *out) {
    SmartHandle smart = (SmartHandle)handle;
    NVMeSMARTData data;
    memset(&data, 0, sizeof data);
    if ((*smart)->SMARTReadData(smart, &data) != kIOReturnSuccess) return -1;
    out->criticalWarning = data.CRITICAL_WARNING;
    out->temperatureKelvin = data.TEMPERATURE;
    out->availableSpare = data.AVAILABLE_SPARE;
    out->availableSpareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
    out->percentageUsed = data.PERCENTAGE_USED;
    out->dataUnitsRead = data.DATA_UNITS_READ[0];
    out->dataUnitsWritten = data.DATA_UNITS_WRITTEN[0];
    out->hostReadCommands = data.HOST_READ_COMMANDS[0];
    out->hostWriteCommands = data.HOST_WRITE_COMMANDS[0];
    out->controllerBusyMinutes = data.CONTROLLER_BUSY_TIME[0];
    out->powerCycles = data.POWER_CYCLES[0];
    out->powerOnHours = data.POWER_ON_HOURS[0];
    out->unsafeShutdowns = data.UNSAFE_SHUTDOWNS[0];
    out->mediaErrors = data.MEDIA_ERRORS[0];
    return 0;
}

void SistemNVMeClose(void *handle) {
    if (handle) (*(SmartHandle)handle)->Release(handle);
}
