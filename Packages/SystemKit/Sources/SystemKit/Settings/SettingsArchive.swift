import Foundation

/// The file format of exported settings: a small versioned envelope around a flat
/// dictionary of JSON values. The app maps keys to its own settings; this layer only
/// guarantees the file is ours, not newer than we understand, and not unreasonable.
///
///     { "app": "Sistem", "schemaVersion": 1, "settings": { "temperatureUnit": "celsius", … } }
///
/// Unknown keys are the caller's to ignore. Later phases add keys without bumping the
/// version; a change that cannot be read by an older build bumps ``currentVersion``, and
/// ``migrate(_:from:)`` upgrades older files.
public enum SettingsArchive {
    public static let currentVersion = 1
    public static let appName = "Sistem"
    /// Settings files are a few KB; anything bigger is not one.
    public static let maxBytes = 512 * 1024

    public enum Failure: Error, Equatable {
        case tooLarge
        case notSettingsFile
        case missingVersion
        case newerVersion(Int)
    }

    public static func encode(_ settings: [String: Any]) throws -> Data {
        let envelope: [String: Any] = ["app": appName, "schemaVersion": currentVersion, "settings": settings]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    /// The settings dictionary of `data`, migrated to the current version.
    public static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["app"] as? String == appName,
              let settings = root["settings"] as? [String: Any] else { throw Failure.notSettingsFile }
        guard let version = root["schemaVersion"] as? Int, version >= 1 else { throw Failure.missingVersion }
        guard version <= currentVersion else { throw Failure.newerVersion(version) }
        return migrate(settings, from: version)
    }

    /// Upgrades `settings` written at `version` to the current layout. Version 1 is the first.
    static func migrate(_ settings: [String: Any], from version: Int) -> [String: Any] {
        settings
    }
}
