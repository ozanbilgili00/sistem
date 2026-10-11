// Display access that has no public API: DDC/CI over IOAVService (Apple Silicon) and the built-in
// display's brightness. Everything is optional and fails soft; nothing here writes brightness.
#include "CPrivate.h"
#include <dlfcn.h>
#include <string.h>

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress, const void *inputBuffer, uint32_t inputBufferSize);

/// Copies the `dispextN` prefix of the first ancestor whose name starts with "dispext" (e.g.
/// "dispext0:dcpav-service-epic:0" gives "dispext0"). Returns 0 when there is none.
static int portOfAncestors(io_registry_entry_t entry, char *port, size_t size) {
    io_registry_entry_t current = entry;
    IOObjectRetain(current);
    int found = 0;
    for (int depth = 0; depth < 16 && !found; depth++) {
        io_name_t name;
        if (IORegistryEntryGetName(current, name) == KERN_SUCCESS && strncmp(name, "dispext", 7) == 0) {
            size_t length = 0;
            while (name[length] != '\0' && name[length] != ':' && length + 1 < size) length++;
            memcpy(port, name, length);
            port[length] = '\0';
            found = 1;
            break;
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(current);
        current = parent;
    }
    IOObjectRelease(current);
    return found;
}

int SistemAVProxies(SistemAVProxy *out, int capacity) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) != KERN_SUCCESS) return 0;
    int count = 0;
    io_service_t service;
    while (count < capacity && (service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, 0);
        int external = location && CFGetTypeID(location) == CFStringGetTypeID() && CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo;
        if (location) CFRelease(location);
        uint64_t registryID = 0;
        SistemAVProxy proxy;
        memset(&proxy, 0, sizeof proxy);
        if (external && IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS
            && portOfAncestors(service, proxy.port, sizeof proxy.port)) {
            proxy.registryID = registryID;
            out[count++] = proxy;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

static int hexValue(CFStringRef string, CFIndex start, int digits) {
    int value = 0;
    for (int i = 0; i < digits; i++) {
        UniChar c = CFStringGetCharacterAtIndex(string, start + i);
        int digit = (c >= '0' && c <= '9') ? c - '0' : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : -1;
        if (digit < 0) return -1;
        value = value * 16 + digit;
    }
    return value;
}

int SistemAVHints(SistemAVHint *out, int capacity) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDCPDPTXRemotePortUFP"), &iterator) != KERN_SUCCESS) return 0;
    int count = 0;
    io_service_t service;
    while (count < capacity && (service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef hints = IORegistryEntryCreateCFProperty(service, CFSTR("DisplayHints"), kCFAllocatorDefault, 0);
        if (hints && CFGetTypeID(hints) == CFDictionaryGetTypeID()) {
            CFTypeRef uuid = CFDictionaryGetValue(hints, CFSTR("EDID UUID"));
            // "VVVVPPPP-…": manufacturer ID, then the product code with its two bytes swapped.
            if (uuid && CFGetTypeID(uuid) == CFStringGetTypeID() && CFStringGetLength(uuid) >= 8) {
                int vendor = hexValue(uuid, 0, 4), swapped = hexValue(uuid, 4, 4);
                SistemAVHint hint;
                memset(&hint, 0, sizeof hint);
                if (vendor >= 0 && swapped >= 0 && portOfAncestors(service, hint.port, sizeof hint.port)) {
                    hint.vendor = (uint16_t)vendor;
                    hint.product = (uint16_t)(((swapped & 0xFF) << 8) | (swapped >> 8));
                    out[count++] = hint;
                }
            }
        }
        if (hints) CFRelease(hints);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

void *SistemAVOpen(uint64_t registryID) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (service == IO_OBJECT_NULL) return NULL;
    IOAVServiceRef ref = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
    IOObjectRelease(service);
    return (void *)ref;
}

void SistemAVClose(void *handle) {
    if (handle) CFRelease((CFTypeRef)handle);
}

int SistemAVRead(void *handle, uint32_t chip, uint32_t offset, uint8_t *buffer, uint32_t length) {
    return IOAVServiceReadI2C((IOAVServiceRef)handle, chip, offset, buffer, length);
}

int SistemAVWrite(void *handle, uint32_t chip, uint32_t offset, const uint8_t *buffer, uint32_t length) {
    return IOAVServiceWriteI2C((IOAVServiceRef)handle, chip, offset, buffer, length);
}

int SistemInternalBrightness(uint32_t displayID, float *out) {
    static int (*getBrightness)(uint32_t, float *);
    static int resolved;
    if (!resolved) {
        resolved = 1;
        void *library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        if (library) getBrightness = (int (*)(uint32_t, float *))dlsym(library, "DisplayServicesGetBrightness");
    }
    if (!getBrightness) return -1;
    return getBrightness(displayID, out);
}
