import XCTest
@testable import FujiDropKit

final class RAFHeaderTests: XCTestCase {
    private func header(model: String, offset: UInt32, length: UInt32) -> Data {
        var b = [UInt8](repeating: 0, count: RAFHeader.readLength)
        let magic = Array("FUJIFILMCCD-RAW ".utf8)
        b.replaceSubrange(0..<magic.count, with: magic)
        let m = Array(model.utf8)
        b.replaceSubrange(0x1C..<(0x1C + m.count), with: m)
        func put(_ v: UInt32, _ i: Int) {
            b[i] = UInt8(v >> 24); b[i + 1] = UInt8(v >> 16 & 0xFF)
            b[i + 2] = UInt8(v >> 8 & 0xFF); b[i + 3] = UInt8(v & 0xFF)
        }
        put(offset, 0x54)
        put(length, 0x58)
        return Data(b)
    }

    func testParsesModelAndPreviewLocation() {
        let h = RAFHeader(header(model: "X-T1", offset: 0x94, length: 1_234_567))
        XCTAssertEqual(h, RAFHeader(cameraModel: "X-T1", jpegOffset: 0x94, jpegLength: 1_234_567))
    }

    func testRejectsNonRAF() {
        XCTAssertNil(RAFHeader(Data(repeating: 0x41, count: 256)))
        XCTAssertNil(RAFHeader(Data("FUJIFILM".utf8)))
    }

    func testRejectsMissingPreview() {
        XCTAssertNil(RAFHeader(header(model: "X-T1", offset: 0, length: 0)))
    }
}
