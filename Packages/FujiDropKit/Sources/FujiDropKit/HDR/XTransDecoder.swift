import CLibRaw
import Foundation
import ImageIO

/// One RAF decoded by LibRaw with 1-pass Markesteijn (X-Trans) demosaicing, kept linear.
///
/// Pixels are LibRaw's 16-bit output: white-balanced with the as-shot multipliers (`wb`),
/// black-subtracted, scaled so sensor saturation is 65535 on the least-amplified channel, and
/// clipped at 65535. Divide a channel by `wb[c] * 65535` for camera-native linear RGB (1.0 =
/// sensor saturation). Kept as UInt16 rather than Float: about 96 MB per X-T1 frame instead of
/// 192 MB, and the merge converts one strip at a time.
/// (`@unchecked`: `properties` holds immutable property-list values.)
public struct XTransImage: @unchecked Sendable {
    public var width: Int
    public var height: Int
    /// Interleaved RGB, upright (the camera's orientation is already applied).
    public var pixels: [UInt16]
    /// As-shot white-balance multipliers LibRaw applied (R, G, B), smallest = 1.
    public var wb: [Float]
    /// XYZ (D65) → camera matrix, 3×3 row-major, as LibRaw has it (Adobe's ColorMatrix).
    public var camXYZ: [Float]
    public var make: String
    public var model: String
    public var exposure: Exposure?
    /// The RAF's EXIF/TIFF properties (ImageIO), for copying into outputs.
    public var properties: [String: Any]

    public init(width: Int, height: Int, pixels: [UInt16], wb: [Float], camXYZ: [Float],
                make: String = "", model: String = "", exposure: Exposure?, properties: [String: Any] = [:]) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.wb = wb
        self.camXYZ = camXYZ
        self.make = make
        self.model = model
        self.exposure = exposure
        self.properties = properties
    }
}

public enum XTransDecoder {
    public enum DecodeError: LocalizedError {
        case libraw(String, Int32)
        case outOfMemory
        case unexpectedFormat(String)
        case notXTrans(String)

        public var errorDescription: String? {
            switch self {
            case .libraw(let step, let code):
                return "LibRaw \(step) failed: \(String(cString: libraw_strerror(code)))"
            case .outOfMemory: return "Not enough memory to decode the RAW file"
            case .unexpectedFormat(let what): return "Unexpected LibRaw output: \(what)"
            case .notXTrans(let model): return "\(model.isEmpty ? "This camera" : model) doesn't have an X-Trans sensor"
            }
        }
    }

    /// LibRaw's version string, for the log and Acknowledgements.
    public static var libRawVersion: String { String(cString: libraw_version()) }

    /// Decodes a RAF. Heavy (hundreds of MB while running on a 16 MP frame): call it off the
    /// main thread and decode bracket frames one after another, not in parallel.
    ///
    /// LibRaw's Markesteijn is single-threaded without OpenMP (which Apple's clang lacks), about
    /// 8 s for an X-T1 frame on one core. So the frame is split into `bands` horizontal bands,
    /// each decoded by its own LibRaw instance on a crop of the sensor (LibRaw's `cropbox`,
    /// aligned to the 6×6 X-Trans pattern) with an overlap that's thrown away, in parallel.
    /// LibRaw itself is unchanged. `bands: 1` decodes the whole frame in one go. Measured on an
    /// M-series Mac: 8.0 s whole, 2.2 s in 4 bands; the output differs only along the seams of
    /// LibRaw's own internal tiles, which move.
    public static func decode(_ url: URL, bands: Int = defaultBands) throws -> XTransImage {
        // Sensor size and orientation, without unpacking.
        let probe = try open(url, crop: nil, keepFlip: true)
        let sensorW = Int(probe.pointee.sizes.width), sensorH = Int(probe.pointee.sizes.height)
        let flip = Int(probe.pointee.sizes.flip)
        let idata = probe.pointee.idata
        let make = withUnsafeBytes(of: idata.make) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let model = withUnsafeBytes(of: idata.model) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let other = probe.pointee.other
        // LibRaw marks X-Trans with filters == 9. The demosaic settings, 6-row band alignment
        // and colour cleanup all assume it, so a Bayer RAW is refused rather than mis-rendered.
        let isXTrans = idata.filters == 9
        libraw_close(probe)
        guard isXTrans else { throw DecodeError.notXTrans(model) }

        // Bands in sensor rows, each decoded with `overlap` extra rows above and below.
        let n = max(1, min(bands, sensorH / 256))
        let overlap = 24 // a multiple of 6; Markesteijn's border handling needs well under this
        var sensor = [UInt16](repeating: 0, count: sensorW * sensorH * 3)
        var color: (wb: [Float], camXYZ: [Float])?
        var failure: Error?
        let lock = NSLock()
        sensor.withUnsafeMutableBufferPointer { out in
            let out = SendableBox(out)
            DispatchQueue.concurrentPerform(iterations: n) { k in
                let y0 = sensorH * k / n, y1 = sensorH * (k + 1) / n
                let cy = n == 1 ? 0 : max(0, y0 - overlap) / 6 * 6
                let ch = n == 1 ? sensorH : min(sensorH, y1 + overlap) - cy
                do {
                    let lr = try open(url, crop: n == 1 ? nil : (0, cy, sensorW, ch))
                    defer { libraw_close(lr) }
                    var code = libraw_unpack(lr)
                    guard code == 0 else { throw DecodeError.libraw("unpack", code) }
                    code = libraw_dcraw_process(lr)
                    guard code == 0 else { throw DecodeError.libraw("process", code) }
                    var err: Int32 = 0
                    guard let mem = libraw_dcraw_make_mem_image(lr, &err) else {
                        throw DecodeError.libraw("make image", err)
                    }
                    defer { libraw_dcraw_clear_mem(mem) }
                    let w = Int(mem.pointee.width), h = Int(mem.pointee.height)
                    guard mem.pointee.colors == 3, mem.pointee.bits == 16, w == sensorW, h == ch else {
                        throw DecodeError.unexpectedFormat("\(w)x\(h), \(mem.pointee.colors) colours, \(mem.pointee.bits) bits")
                    }
                    // `data` is a C flexible array member: the pixels start at its offset.
                    let offset = MemoryLayout<libraw_processed_image_t>.offset(of: \.data)!
                    let src = UnsafeRawPointer(mem).advanced(by: offset).assumingMemoryBound(to: UInt16.self)
                    let rowLength = sensorW * 3
                    for y in y0..<y1 {
                        (out.value.baseAddress! + y * rowLength)
                            .update(from: src + (y - cy) * rowLength, count: rowLength)
                    }
                    if k == 0 {
                        let c = colorData(lr)
                        lock.lock(); color = c; lock.unlock()
                    }
                } catch {
                    lock.lock(); failure = error; lock.unlock()
                }
            }
        }
        if let failure { throw failure }
        guard let color else { throw DecodeError.unexpectedFormat("no colour data") }

        let (pixels, w, h) = applyFlip(sensor, width: sensorW, height: sensorH, flip: flip)

        let (wb, camXYZ) = color

        let props = ImageLoading.properties(at: url)
        let exposure = Exposure(properties: props) ?? Exposure(
            time: Double(other.shutter), fNumber: Double(other.aperture), iso: Double(other.iso_speed), bias: 0,
            date: other.timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(other.timestamp)) : nil)
        return XTransImage(width: w, height: h, pixels: pixels, wb: wb, camXYZ: camXYZ,
                           make: make, model: model, exposure: exposure, properties: props)
    }

    /// The white-balance multipliers and colour matrix of a processed frame, read through the
    /// pointer: `libraw_colordata_t` is 187 KB, and copying it (`lr.pointee.color`) onto a
    /// dispatch worker's 512 KB stack overflowed it on the iPhone.
    private static func colorData(_ lr: UnsafeMutablePointer<libraw_data_t>) -> (wb: [Float], camXYZ: [Float]) {
        let color = UnsafeRawPointer(lr).advanced(by: MemoryLayout<libraw_data_t>.offset(of: \.color)!)
        func floats(_ field: PartialKeyPath<libraw_colordata_t>, _ count: Int) -> [Float] {
            let p = color.advanced(by: MemoryLayout<libraw_colordata_t>.offset(of: field)!)
                .assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: p, count: count))
        }
        // After processing, pre_mul holds the multipliers actually applied, normalized so the
        // smallest is 1 (with highlight clipping).
        let wb = floats(\libraw_colordata_t.pre_mul, 3).map { $0 > 0 ? $0 : 1 }
        // cam_xyz is [4][3]: the first three rows are R, G, B.
        return (wb, floats(\libraw_colordata_t.cam_xyz, 9))
    }

    /// Four bands: a 4× speed-up on a Mac or the iPhone's cores, at a few hundred MB peak.
    public static let defaultBands = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// An opened (not unpacked) LibRaw handle with our decode parameters; close it after use.
    private static func open(_ url: URL, crop: (Int, Int, Int, Int)?, keepFlip: Bool = false) throws -> UnsafeMutablePointer<libraw_data_t> {
        guard let lr = libraw_init(0) else { throw DecodeError.outOfMemory }
        // Markesteijn works best on white-balanced data, so demosaic with the camera's WB and
        // divide it back out later (the multipliers are returned).
        lr.pointee.params.use_camera_wb = 1
        lr.pointee.params.user_qual = 2             // X-Trans: Markesteijn 1-pass
        lr.pointee.params.output_color = 0          // raw camera colour, no matrix
        lr.pointee.params.gamm.0 = 1
        lr.pointee.params.gamm.1 = 1
        lr.pointee.params.no_auto_bright = 1
        lr.pointee.params.output_bps = 16
        lr.pointee.params.highlight = 0             // clip
        // Decode in sensor orientation; `applyFlip` rotates the stitched result. (The probe
        // keeps the camera's flip, to read it.)
        if !keepFlip { lr.pointee.params.user_flip = 0 }
        // Don't lower the white point to the brightest value found: every frame of a bracket
        // (and every band) must use the same scale, sensor saturation.
        lr.pointee.params.adjust_maximum_thr = 0
        if let crop {
            lr.pointee.params.cropbox = (UInt32(crop.0), UInt32(crop.1), UInt32(crop.2), UInt32(crop.3))
        }
        let code = libraw_open_file(lr, url.path)
        guard code == 0 else {
            libraw_close(lr)
            throw DecodeError.libraw("open", code)
        }
        return lr
    }

    /// Applies LibRaw's `flip` (bit 4: transpose, 2: flip rows, 1: flip columns; as its
    /// `flip_index`) to interleaved RGB.
    static func applyFlip(_ src: [UInt16], width: Int, height: Int, flip: Int) -> ([UInt16], Int, Int) {
        guard flip & 7 != 0 else { return (src, width, height) }
        let outW = flip & 4 != 0 ? height : width
        let outH = flip & 4 != 0 ? width : height
        var out = [UInt16](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                let d = SendableBox(d)
                DispatchQueue.concurrentPerform(iterations: outH) { r in
                    for c in 0..<outW {
                        var row = r, col = c
                        if flip & 4 != 0 { swap(&row, &col) }
                        if flip & 2 != 0 { row = height - 1 - row }
                        if flip & 1 != 0 { col = width - 1 - col }
                        let si = (row * width + col) * 3, di = (r * outW + c) * 3
                        d.value[di] = s[si]; d.value[di + 1] = s[si + 1]; d.value[di + 2] = s[si + 2]
                    }
                }
            }
        }
        return (out, outW, outH)
    }
}
