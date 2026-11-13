import Foundation
import Testing
@testable import PulseCore

@Test func uint16RoundTrip() {
    let values: [UInt16] = [0, 1, 255, 256, 909, 1639, 65535]
    #expect(BinaryCoding.decodeUInt16(BinaryCoding.encode(values)) == values)
}

@Test func uint16IsLittleEndian() {
    // 1639 = 0x0667 -> bytes 67 06, exactly like the RR value in the WHOOP realtime sample.
    #expect([UInt8](BinaryCoding.encode([1639])) == [0x67, 0x06])
}

@Test func oddTrailingByteIsIgnored() {
    #expect(BinaryCoding.decodeUInt16(Data([0x67, 0x06, 0xFF])) == [1639])
    #expect(BinaryCoding.decodeUInt16(Data()) == [])
}
