import Foundation

/// Did the tool that signed this install keep the HealthKit permission?
///
/// The IPA asks for HealthKit, but what counts is the provisioning profile the signing tool got from
/// Apple. Without HealthKit in that profile iOS refuses every Apple Health call, shows no permission
/// sheet, and Pulse never appears in Settings > Health > Data Access & Devices.
public enum HealthAccess {
    public enum Signing: String, Sendable, Equatable {
        /// The profile includes HealthKit.
        case granted
        /// The profile leaves HealthKit out, so Apple Health can't work on this install.
        case missing
        /// No readable profile (the simulator, for example).
        case unknown
    }

    public static let entitlement = "com.apple.developer.healthkit"

    public static let missingMessage = "The tool that signed this copy of Pulse left out Apple Health access, so iOS won't "
        + "let Pulse use it. Use Export all data below as your backup."

    /// - Parameter data: the bytes of `embedded.mobileprovision`. It is a signed file with a plist inside.
    public static func signing(embeddedProfile data: Data?) -> Signing {
        guard let data, let plist = plistBytes(in: data),
              let object = try? PropertyListSerialization.propertyList(from: plist, format: nil),
              let profile = object as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else { return .unknown }
        return entitlements[entitlement] as? Bool == true ? .granted : .missing
    }

    private static func plistBytes(in data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}
