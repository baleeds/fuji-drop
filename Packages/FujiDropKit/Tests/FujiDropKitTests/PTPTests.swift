import XCTest
@testable import FujiDropKit

final class PTPTests: XCTestCase {
    func testCommandContainerLayout() {
        let data = PTP.commandContainer(0x1015, transactionID: 7, params: [0x5011])
        XCTAssertEqual([UInt8](data), [
            0x10, 0x00, 0x00, 0x00, // length 16
            0x01, 0x00,             // command block
            0x15, 0x10,             // GetDevicePropValue
            0x07, 0x00, 0x00, 0x00, // transaction 7
            0x11, 0x50, 0x00, 0x00, // DateTime
        ])
    }

    func testParseResponse() {
        let bytes: [UInt8] = [0x10, 0, 0, 0, 0x03, 0, 0x01, 0x20, 0x07, 0, 0, 0, 0x2A, 0, 0, 0]
        let r = PTP.parseResponse(Data(bytes))
        XCTAssertEqual(r, PTP.Response(code: 0x2001, transactionID: 7, params: [42]))
        XCTAssertEqual(r?.isOK, true)
        XCTAssertEqual(r?.name, "OK")
    }

    func testParseResponseRejectsDataBlock() {
        let bytes: [UInt8] = [0x0C, 0, 0, 0, 0x02, 0, 0x01, 0x20, 0x07, 0, 0, 0]
        XCTAssertNil(PTP.parseResponse(Data(bytes)))
    }

    func testPayloadStripsDataHeaderOnlyWhenPresent() {
        let payload: [UInt8] = [0xAA, 0xBB]
        let wrapped: [UInt8] = [0x0E, 0, 0, 0, 0x02, 0, 0x15, 0x10, 0x01, 0, 0, 0] + payload
        XCTAssertEqual([UInt8](PTP.payload(fromDataPhase: Data(wrapped))), payload)
        XCTAssertEqual([UInt8](PTP.payload(fromDataPhase: Data(payload))), payload)
    }

    func testStringRoundTrip() {
        let encoded = PTP.encodeString("20261127T101500")
        XCTAssertEqual(encoded.first, 16) // 15 chars + null
        XCTAssertEqual(encoded.count, 1 + 16 * 2)
        let decoded = PTP.decodeString(encoded)
        XCTAssertEqual(decoded?.0, "20261127T101500")
        XCTAssertEqual(decoded?.1, encoded.count)
    }

    func testEmptyString() {
        XCTAssertEqual([UInt8](PTP.encodeString("")), [0])
        XCTAssertEqual(PTP.decodeString(Data([0]))?.0, "")
    }

    func testDateTimeParsingLocal() {
        let tz = TimeZone(identifier: "America/New_York")!
        let date = PTP.parseDateTime("20261127T101500", timeZone: tz)
        XCTAssertEqual(date.map { PTP.formatDateTime($0, timeZone: tz) }, "20261127T101500")
    }

    func testDateTimeParsingWithZoneAndFraction() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let z = PTP.parseDateTime("20261127T101500.0Z")
        XCTAssertEqual(z.map { PTP.formatDateTime($0, timeZone: utc) }, "20261127T101500")
        let offset = PTP.parseDateTime("20261127T101500-0500")
        XCTAssertEqual(offset.map { PTP.formatDateTime($0, timeZone: utc) }, "20261127T151500")
    }

    func testDateTimeRejectsGarbage() {
        XCTAssertNil(PTP.parseDateTime("not a date"))
        XCTAssertNil(PTP.parseDateTime("2026-11-27 10:15"))
    }
}
