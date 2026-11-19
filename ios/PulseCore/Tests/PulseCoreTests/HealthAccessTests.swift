import Foundation
import Testing
@testable import PulseCore

// Can this install use Apple Health? Read from the provisioning profile the signing tool produced.

private func profile(entitlements: String) -> Data {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>Name</key><string>Test</string>
    <key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
    """
    // A real profile wraps the plist in binary signature bytes on both sides.
    return Data([0x30, 0x82, 0x1F, 0x00]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0xFF])
}

@Test func aProfileWithHealthKitIsGranted() {
    let data = profile(entitlements: "<key>com.apple.developer.healthkit</key><true/>")
    #expect(HealthAccess.signing(embeddedProfile: data) == .granted)
}

@Test func aProfileWithoutHealthKitIsMissing() {
    let data = profile(entitlements: "<key>application-identifier</key><string>ABC.dev.pulse.app</string>")
    #expect(HealthAccess.signing(embeddedProfile: data) == .missing)
}

@Test func healthKitSetToFalseIsMissing() {
    let data = profile(entitlements: "<key>com.apple.developer.healthkit</key><false/>")
    #expect(HealthAccess.signing(embeddedProfile: data) == .missing)
}

@Test func noReadableProfileIsUnknown() {
    #expect(HealthAccess.signing(embeddedProfile: nil) == .unknown)
    #expect(HealthAccess.signing(embeddedProfile: Data([1, 2, 3])) == .unknown)
    #expect(HealthAccess.signing(embeddedProfile: Data("<?xml broken".utf8)) == .unknown)
}
