import Foundation

/// The fixed header at the start of a Fujifilm RAF file. We only need it to locate the
/// embedded JPEG preview so we can read just that slice of the file over the cable.
///
/// Layout (big-endian):
///   0x00  16 bytes  "FUJIFILMCCD-RAW " magic
///   0x1C  32 bytes  camera model, NUL-terminated ASCII
///   0x54  UInt32    embedded JPEG offset
///   0x58  UInt32    embedded JPEG length
public struct RAFHeader: Equatable, Sendable {
    public static let magic = "FUJIFILMCCD-RAW"
    /// Bytes to read to parse the header.
    public static let readLength = 0x100

    public var cameraModel: String
    public var jpegOffset: Int
    public var jpegLength: Int

    public init(cameraModel: String, jpegOffset: Int, jpegLength: Int) {
        self.cameraModel = cameraModel
        self.jpegOffset = jpegOffset
        self.jpegLength = jpegLength
    }

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x5C,
              String(decoding: bytes[0..<Self.magic.utf8.count], as: UTF8.self) == Self.magic
        else { return nil }
        let modelBytes = bytes[0x1C..<0x3C].prefix { $0 != 0 }
        cameraModel = String(decoding: modelBytes, as: UTF8.self)
        jpegOffset = Int(Self.readBE(bytes, at: 0x54))
        jpegLength = Int(Self.readBE(bytes, at: 0x58))
        guard jpegOffset > 0, jpegLength > 0 else { return nil }
    }

    private static func readBE(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
