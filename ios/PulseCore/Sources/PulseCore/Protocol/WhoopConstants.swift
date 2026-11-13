import Foundation

/// WHOOP 4.0 ("gen4") Bluetooth protocol: Swift port of re-toolkit/protocol.
///
/// The Python package is the source of truth; this port must reproduce
/// shared/test-vectors/protocol_v1.json exactly (see ProtocolParityTests).
/// Every fact and its confidence level is documented in re-toolkit/docs/PROTOCOL.md.
/// Sources: bWanShiTong/reverse-engineering-whoop-post, OpenStrap/protocol (facts only, no code copied).
public enum Whoop {

    // MARK: - Bluetooth identifiers (lowercase strings; the app wraps them in CBUUID)

    public static let uuidSuffix = "-8d6d-82b8-614a-1c8cb0f8dcc6"
    /// UNKNOWN which one: notes/[CM] say ...0000, [OS] says ...0001. Match by prefix instead.
    public static let serviceUUIDCandidates = ["61080000" + uuidSuffix, "61080001" + uuidSuffix]
    public static let uuidPrefix = "6108"

    public static let cmdToStrapUUID = "61080002" + uuidSuffix     // write with response
    public static let cmdFromStrapUUID = "61080003" + uuidSuffix   // notify: command responses
    public static let eventsUUID = "61080004" + uuidSuffix         // notify: events
    public static let dataUUID = "61080005" + uuidSuffix           // notify: realtime + history
    public static let memfaultUUID = "61080007" + uuidSuffix       // notify: crash logs

    /// Standard Bluetooth SIG Heart Rate service + measurement characteristic.
    public static let heartRateServiceUUID = "0000180d-0000-1000-8000-00805f9b34fb"
    public static let heartRateMeasurementUUID = "00002a37-0000-1000-8000-00805f9b34fb"

    // MARK: - Frame constants (VERIFIED)

    public static let startOfFrame: UInt8 = 0xAA
    public static let headerLength = 4
    public static let crc32Length = 4
    public static let maxFrameLength = 4096

    // MARK: - Enums

    public enum PacketType: UInt8, CaseIterable, Sendable {
        case command = 0x23, commandResponse = 0x24, realtimeData = 0x28, realtimeRaw = 0x2B
        case historicalData = 0x2F, event = 0x30, metadata = 0x31, consoleLogs = 0x32
        case realtimeIMU = 0x33, historicalIMU = 0x34
    }

    public enum Cmd: UInt8, CaseIterable, Sendable {
        case linkValid = 0x01
        case toggleRealtimeHr = 0x03
        case reportVersionInfo = 0x07
        case setClock = 0x0A
        case getClock = 0x0B
        case setGenericHrProfile = 0x0E
        case forgetBonds = 0x0F
        case abortHistorical = 0x14
        case sendHistoricalData = 0x16
        case historicalDataResult = 0x17
        case forceTrim = 0x19
        case getBatteryLevel = 0x1A
        case reboot = 0x1D
        case powerCycle = 0x20
        case setReadPointer = 0x21
        case getDataRange = 0x22
        case getHelloHarvard = 0x23
        case startUpdateLoad = 0x24
        case loadUpdateData = 0x25
        case processUpdateImage = 0x26
        case setAlarmTime = 0x42
        case getAlarmTime = 0x43
        case getAdvertisingName = 0x4C
        case getBodyLocationAndStatus = 0x54
        case getExtendedBatteryInfo = 0x62
        case getConfigKeyCount = 0x73
        case getConfigKeyName = 0x74
        case setSignalConfig = 0x8A
        case getHello = 0x91
        case wearDetectOverride = 0x94
        case setLedAccessibility = 0x95
        case persistentOpticalSave = 0x99
        case togglePersistentR21 = 0x9A
    }

    public enum ResponseStatus: UInt8, CaseIterable, Sendable {
        case failed = 0, ok = 1, deferred = 2, notImplemented = 3
    }

    public enum MetaType: UInt8, CaseIterable, Sendable {
        case historyStart = 1, historyEnd = 2, historyComplete = 3
    }

    public enum EventID: UInt16, CaseIterable, Sendable {
        case batteryLevel = 3, chargingOn = 7, chargingOff = 8, wristOn = 9, wristOff = 10
        case rtcLost = 13, doubleTap = 14, boot = 15, setRtc = 16
        case batteryPackConnected = 21, batteryPackRemoved = 22
        case trimAllData = 26, trimAllDataEnded = 27, flashInitComplete = 28, strapConditionReport = 29
        case bleBonded = 31, bleRealtimeHrOn = 33, bleRealtimeHrOff = 34
        case strapDrivenAlarmSet = 56, strapDrivenAlarmExecuted = 57, appDrivenAlarmExecuted = 58
        case strapDrivenAlarmDisabled = 59, hapticsFired = 60, extendedBatteryInformation = 63
        case highFreqSyncPrompt = 96, highFreqSyncEnabled = 97, highFreqSyncDisabled = 98
        case hapticsTerminated = 100, batteryPackInfo = 109, temperatureLevel = 111, genericFirmwareEvent = 123
    }

    // MARK: - SAFETY: the allowlist

    /// Read-only queries: ask, change nothing.
    public static let readOnlyCommands: Set<Cmd> = [
        .linkValid, .reportVersionInfo, .getClock, .getBatteryLevel, .getDataRange, .getHelloHarvard,
        .getAlarmTime, .getAdvertisingName, .getBodyLocationAndStatus, .getExtendedBatteryInfo, .getHello,
    ]
    /// Normal app behaviour that changes band state. The app only sends these on purpose.
    public static let statefulCommands: Set<Cmd> = [
        .toggleRealtimeHr, .setGenericHrProfile, .setClock, .sendHistoricalData, .historicalDataResult,
        .abortHistorical,
    ]
    /// Everything else, including opcodes nobody has documented, cannot be built. There is deliberately
    /// no override: adding a command means editing this list in a reviewed commit.
    public static let allowedOpcodes: Set<UInt8> = Set((readOnlyCommands.union(statefulCommands)).map(\.rawValue))

    // MARK: - Helpers

    /// Unix timestamps outside 2020...2100 are treated as garbage (e.g. an unset band clock).
    public static func plausibleUnix(_ ts: UInt32) -> Bool {
        (1_600_000_000...4_102_444_800).contains(UInt64(ts))
    }

    /// "GET_BATTERY_LEVEL" for a known value, "0x5a?" for an unknown one (same as the Python tools).
    static func name<E: RawRepresentable>(_ type: E.Type, _ value: Int) -> String
    where E.RawValue: FixedWidthInteger {
        if value >= 0, let raw = E.RawValue(exactly: value), let known = E(rawValue: raw) {
            return screamingSnake(String(describing: known))
        }
        if value < 0 { return "0x-\(String(-value, radix: 16))?" }   // same text as Python's f"{-1:02x}"
        return String(format: "0x%02x?", value)
    }

    /// "getBatteryLevel" -> "GET_BATTERY_LEVEL"
    static func screamingSnake(_ camel: String) -> String {
        var out = ""
        for ch in camel {
            if ch.isUppercase && !out.isEmpty { out.append("_") }
            out.append(contentsOf: ch.uppercased())
        }
        return out
    }
}
