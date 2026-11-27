import Foundation
import ImageIO

/// Writes a demosaiced *linear* DNG (like Apple ProRAW, HDRMerge and Iridient X-Transformer):
/// RGB half floats that editors treat as RAW, so white balance and exposure stay adjustable.
/// iOS reads DNG but can't write it, hence this minimal TIFF writer (docs/HDR-PLAN.md, step 4).
///
/// Layout: IFD0 is an 8-bit sRGB preview (NewSubfileType 1), its SubIFD the main image
/// (LinearRaw, 3 × 16-bit float or integer, 256 px tiles), and an EXIF IFD carries the source
/// frame's capture settings. Little-endian.
///
/// Core Image (so Photos) decodes only uncompressed or lossless-JPEG DNG tiles: it refused
/// Deflate with every predictor, float and integer (macOS 27), though desktop editors read it.
/// So integer images use lossless JPEG and half floats stay uncompressed.
public enum DNGWriter {
    public struct Preview: Sendable {
        public var width: Int
        public var height: Int
        /// Interleaved 8-bit sRGB.
        public var rgb: [UInt8]

        public init(width: Int, height: Int, rgb: [UInt8]) {
            self.width = width
            self.height = height
            self.rgb = rgb
        }
    }

    public enum WriteError: LocalizedError {
        case cannotCreate(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let name): return "Could not create \(name)"
            }
        }
    }

    public static let tileSize = 256

    public enum Compression: Sendable {
        case none
        /// Lossless JPEG (Compression 7); integer samples only. About half size.
        case losslessJPEG
    }

    /// - Parameters:
    ///   - baselineExposure: stops a converter should add by default (BaselineExposure).
    ///   - compression: `.losslessJPEG` for integer images; half floats are stored uncompressed.
    public static func write(_ image: LinearImage, to url: URL, baselineExposure: Double,
                             preview: Preview?, compression: Compression = .none) throws {
        precondition(compression != .losslessJPEG || !image.samples.isFloat, "lossless JPEG needs integer samples")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else { throw WriteError.cannotCreate(url.lastPathComponent) }
        defer { try? file.close() }

        // Header; IFD0's offset is patched at the end.
        var header = Data("II".utf8)
        header.append(le16(42))
        header.append(le32(0))
        try file.write(contentsOf: header)
        var offset = UInt32(header.count)

        // Main image tiles, compressed in parallel, written in order.
        let tilesAcross = (image.width + tileSize - 1) / tileSize
        let tilesDown = (image.height + tileSize - 1) / tileSize
        var tileOffsets: [UInt32] = []
        var tileCounts: [UInt32] = []
        for row in 0..<tilesDown {
            var tiles = [Data](repeating: Data(), count: tilesAcross)
            tiles.withUnsafeMutableBufferPointer { out in
                let out = SendableBox(out)
                DispatchQueue.concurrentPerform(iterations: tilesAcross) { col in
                    out.value[col] = tile(image, col: col, row: row, compression: compression)
                }
            }
            for t in tiles {
                tileOffsets.append(offset)
                tileCounts.append(UInt32(t.count))
                try file.write(contentsOf: t)
                offset += UInt32(t.count)
                if offset % 2 == 1 { try file.write(contentsOf: Data([0])); offset += 1 }
            }
        }

        // Preview strip.
        var previewOffset: UInt32 = 0
        if let preview {
            previewOffset = offset
            try file.write(contentsOf: Data(preview.rgb))
            offset += UInt32(preview.rgb.count)
            if offset % 2 == 1 { try file.write(contentsOf: Data([0])); offset += 1 }
        }

        let props = image.properties
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String) ?? (image.make.isEmpty ? "FUJIFILM" : image.make)
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String) ?? image.model
        let dateTime = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String)

        // EXIF IFD.
        var exifIFD = IFD()
        if let t = Exposure.number(exif[kCGImagePropertyExifExposureTime as String]) { exifIFD.rational(33434, [t]) }
        if let n = Exposure.number(exif[kCGImagePropertyExifFNumber as String]) { exifIFD.rational(33437, [n]) }
        if let iso = Exposure.number((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first) {
            exifIFD.short(34855, [UInt16(min(iso, 65535))])
        }
        exifIFD.add(36864, type: 7, count: 4, Data("0230".utf8)) // ExifVersion
        if let dateTime { exifIFD.ascii(36867, dateTime) }
        if let b = Exposure.number(exif[kCGImagePropertyExifExposureBiasValue as String]) { exifIFD.srational(37380, [b]) }
        if let f = Exposure.number(exif[kCGImagePropertyExifFocalLength as String]) { exifIFD.rational(37386, [f]) }
        if let lensMake = exif[kCGImagePropertyExifLensMake as String] as? String { exifIFD.ascii(42035, lensMake) }
        if let lens = exif[kCGImagePropertyExifLensModel as String] as? String { exifIFD.ascii(42036, lens) }

        // Main image IFD (SubIFD of IFD0).
        var main = IFD()
        main.long(254, [0])
        main.long(256, [UInt32(image.width)])
        main.long(257, [UInt32(image.height)])
        main.short(258, [16, 16, 16])
        main.short(259, [compression == .losslessJPEG ? 7 : 1])
        main.short(262, [34892]) // LinearRaw
        main.short(277, [3])
        main.short(284, [1])
        main.long(322, [UInt32(tileSize)])
        main.long(323, [UInt32(tileSize)])
        main.long(324, tileOffsets)
        main.long(325, tileCounts)
        switch image.samples {
        case .half:
            main.short(339, [3, 3, 3]) // IEEE float
            // WhiteLevel 1.0. The DNG spec makes that the default for float data, but Core
            // Image renders float data without it as black.
            main.long(50717, [1, 1, 1])
        case .integer:
            main.short(339, [1, 1, 1]) // unsigned integer
            main.long(50717, [65535, 65535, 65535]) // black is 0: LibRaw subtracted it
        }
        main.long(50719, [UInt32(image.crop.x), UInt32(image.crop.y)])   // DefaultCropOrigin
        main.long(50720, [UInt32(image.crop.width), UInt32(image.crop.height)]) // DefaultCropSize

        // IFD0: preview plus the DNG tags.
        var ifd0 = IFD()
        ifd0.long(254, [1])
        let pw = UInt32(preview?.width ?? 1), ph = UInt32(preview?.height ?? 1)
        ifd0.long(256, [pw])
        ifd0.long(257, [ph])
        ifd0.short(258, [8, 8, 8])
        ifd0.short(259, [1])
        ifd0.short(262, [2]) // RGB
        ifd0.ascii(271, make)
        ifd0.ascii(272, model)
        ifd0.long(273, [previewOffset])
        ifd0.short(274, [1]) // pixels are already upright
        ifd0.short(277, [3])
        ifd0.long(278, [ph])
        ifd0.long(279, [UInt32(preview?.rgb.count ?? 0)])
        ifd0.short(284, [1])
        ifd0.ascii(305, "Fuji Drop")
        if let dateTime { ifd0.ascii(306, dateTime) }
        ifd0.add(50706, type: 1, count: 4, Data([1, 4, 0, 0])) // DNGVersion
        // DNGBackwardVersion: float data needs a 1.4 reader; 16-bit LinearRaw is fine at 1.1.
        ifd0.add(50707, type: 1, count: 4, Data(image.samples.isFloat ? [1, 4, 0, 0] : [1, 1, 0, 0]))
        ifd0.ascii(50708, "\(make.capitalized) \(model)") // UniqueCameraModel
        ifd0.srational(50721, image.camXYZ.map(Double.init)) // ColorMatrix1 (XYZ → camera)
        let green = Double(image.wb[1])
        ifd0.rational(50728, image.wb.map { green / Double($0) }) // AsShotNeutral
        ifd0.srational(50730, [baselineExposure])
        ifd0.short(50778, [21]) // CalibrationIlluminant1: D65 (LibRaw's Adobe matrices)
        ifd0.long(50970, [1]) // PreviewColorSpace: sRGB

        // Serialize: EXIF, main, then IFD0 (which points at both).
        let exifOffset = offset
        let exifData = exifIFD.serialize(at: exifOffset)
        offset += UInt32(exifData.count)
        let mainOffset = offset
        let mainData = main.serialize(at: mainOffset)
        offset += UInt32(mainData.count)
        ifd0.long(330, [mainOffset])   // SubIFDs
        ifd0.long(34665, [exifOffset]) // ExifIFD
        let ifd0Offset = offset
        let ifd0Data = ifd0.serialize(at: ifd0Offset)
        try file.write(contentsOf: exifData + mainData + ifd0Data)
        try file.seek(toOffset: 4)
        try file.write(contentsOf: le32(ifd0Offset))
    }

    // MARK: Tiles

    /// One tile's bytes: full size, edges padded by repeating the last pixel.
    static func tile(_ image: LinearImage, col: Int, row: Int, compression: Compression) -> Data {
        switch image.samples {
        case .half(let px):
            return gather(px, image, col: col, row: row) // little-endian, as the header says
        case .integer(let px):
            let t = tileSize
            guard compression == .losslessJPEG else { return gather(px, image, col: col, row: row) }
            let values = gather(px, image, col: col, row: row)
            return values.withUnsafeBytes { raw in
                LosslessJPEG.encode(raw.bindMemory(to: UInt16.self), width: t, height: t, components: 3)
            }
        }
    }

    /// A tile's samples copied straight into its bytes (edges padded).
    private static func gather<T>(_ px: [T], _ image: LinearImage, col: Int, row: Int) -> Data {
        let t = tileSize
        var data = Data(count: t * t * 3 * MemoryLayout<T>.stride)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: T.self)
            px.withUnsafeBufferPointer { px in
                for y in 0..<t {
                    let sy = min(row * t + y, image.height - 1)
                    for x in 0..<t {
                        let sx = min(col * t + x, image.width - 1)
                        let s = (sy * image.width + sx) * 3, d = (y * t + x) * 3
                        out[d] = px[s]; out[d + 1] = px[s + 1]; out[d + 2] = px[s + 2]
                    }
                }
            }
        }
        return data
    }

    // MARK: TIFF plumbing

    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// One image file directory: entries sorted by tag, values over 4 bytes placed after it.
    struct IFD {
        struct Entry {
            let tag: UInt16
            let type: UInt16
            let count: UInt32
            let value: Data
        }

        private(set) var entries: [Entry] = []

        mutating func add(_ tag: UInt16, type: UInt16, count: Int, _ value: Data) {
            entries.removeAll { $0.tag == tag }
            entries.append(Entry(tag: tag, type: type, count: UInt32(count), value: value))
        }

        mutating func short(_ tag: UInt16, _ v: [UInt16]) {
            add(tag, type: 3, count: v.count, v.reduce(into: Data()) { $0.append(le16($1)) })
        }

        mutating func long(_ tag: UInt16, _ v: [UInt32]) {
            add(tag, type: 4, count: v.count, v.reduce(into: Data()) { $0.append(le32($1)) })
        }

        mutating func ascii(_ tag: UInt16, _ s: String) {
            var d = Data(s.utf8)
            d.append(0)
            add(tag, type: 2, count: d.count, d)
        }

        mutating func rational(_ tag: UInt16, _ v: [Double]) {
            add(tag, type: 5, count: v.count, v.reduce(into: Data()) { d, x in
                let (n, q) = fraction(max(x, 0), limit: Double(UInt32.max))
                d.append(le32(UInt32(n))); d.append(le32(UInt32(q)))
            })
        }

        mutating func srational(_ tag: UInt16, _ v: [Double]) {
            add(tag, type: 10, count: v.count, v.reduce(into: Data()) { d, x in
                let (n, q) = fraction(x, limit: Double(Int32.max))
                d.append(le32(UInt32(bitPattern: Int32(n)))); d.append(le32(UInt32(q)))
            })
        }

        /// A fraction close to `x` with the largest denominator that keeps both in range.
        private func fraction(_ x: Double, limit: Double) -> (Int64, Int64) {
            guard x.isFinite, x != 0 else { return (0, 1) }
            var q = 1_000_000.0
            while abs(x) * q > limit, q > 1 { q /= 10 }
            return (Int64((x * q).rounded()), Int64(q))
        }

        func serialize(at offset: UInt32) -> Data {
            let sorted = entries.sorted { $0.tag < $1.tag }
            let tableSize = 2 + sorted.count * 12 + 4
            var table = Data()
            var extra = Data()
            table.append(le16(UInt16(sorted.count)))
            for e in sorted {
                table.append(le16(e.tag))
                table.append(le16(e.type))
                table.append(le32(e.count))
                if e.value.count <= 4 {
                    table.append(e.value + Data(count: 4 - e.value.count))
                } else {
                    table.append(le32(offset + UInt32(tableSize + extra.count)))
                    extra.append(e.value)
                    if extra.count % 2 == 1 { extra.append(0) }
                }
            }
            table.append(le32(0)) // no next IFD
            return table + extra
        }
    }
}
