import Foundation

/// Compact byte encodings for storing raw samples (one database row per minute).
///
/// UInt16 values are written little-endian (low byte first), the same byte order the
/// WHOOP band uses, so there's only one convention to remember in this project.
public enum BinaryCoding {

    public static func encode(_ values: [UInt16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for v in values {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8(v >> 8))
        }
        return data
    }

    /// A trailing odd byte (corrupt data) is ignored rather than crashing.
    public static func decodeUInt16(_ data: Data) -> [UInt16] {
        let bytes = [UInt8](data)
        var out: [UInt16] = []
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            out.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            i += 2
        }
        return out
    }
}
