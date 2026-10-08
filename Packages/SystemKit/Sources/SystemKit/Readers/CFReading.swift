import CoreFoundation

/// Plain CF accessors for registry dictionaries: no bridging to `NSDictionary`, so
/// a read leaves no autoreleased temporaries behind (the readers run on a queue
/// with no pool, thousands of times).
enum CFReading {
    static func value(_ dictionary: CFDictionary, _ key: String) -> CFTypeRef? {
        let key = key as CFString
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    }

    static func int64(_ dictionary: CFDictionary, _ key: String) -> Int64? {
        guard let value = value(dictionary, key), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result: Int64 = 0
        return CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &result) ? result : nil
    }

    static func string(_ dictionary: CFDictionary, _ key: String) -> String? {
        guard let value = value(dictionary, key), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    static func dictionary(_ dictionary: CFDictionary, _ key: String) -> CFDictionary? {
        guard let value = value(dictionary, key), CFGetTypeID(value) == CFDictionaryGetTypeID() else { return nil }
        return unsafeDowncast(value, to: CFDictionary.self)
    }
}
