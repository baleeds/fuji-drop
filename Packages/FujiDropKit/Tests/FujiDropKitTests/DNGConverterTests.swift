import CoreImage
@testable import FujiDropKit
import XCTest

/// Converts a real RAF to DNG + JPEG. Set `FUJIDROP_TEST_RAF` (and optionally
/// `FUJIDROP_TEST_OUT` to keep the files); skipped otherwise.
final class DNGConverterTests: XCTestCase {
    func testConvertsRealRAF() throws {
        guard let path = ProcessInfo.processInfo.environment["FUJIDROP_TEST_RAF"] else {
            throw XCTSkip("Set FUJIDROP_TEST_RAF to an X-T1 RAF to run this test.")
        }
        let raw = URL(fileURLWithPath: path)
        let out = ProcessInfo.processInfo.environment["FUJIDROP_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try Data(contentsOf: raw)
        let header = try XCTUnwrap(RAFHeader(data.prefix(RAFHeader.readLength)))
        let preview = out.appendingPathComponent("camera-preview.jpg")
        try data.subdata(in: header.jpegOffset..<header.jpegOffset + header.jpegLength).write(to: preview)

        let started = Date()
        let result = try DNGConverter.convert(raw: raw, preview: preview, name: "CONVERTED", into: out)
        print(String(format: "DNG save total %.2f s", Date().timeIntervalSince(started)))
        result.report.forEach { print("DNG save:", $0) }

        let size = (try FileManager.default.attributesOfItem(atPath: result.dng.path)[.size] as? Int) ?? 0
        print("DNG \(size / 1_000_000) MB")
        XCTAssertLessThan(size, 75_000_000)
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: result.dng))
        XCTAssertGreaterThan(filter.nativeSize.width, 3000) // the main image, not the preview
        XCTAssertNotNil(filter.outputImage)
        let jpeg = try XCTUnwrap(CGImageSourceCreateWithURL(result.jpeg as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(jpeg, 0, nil) as? [String: Any]
        XCTAssertNotNil(props?[kCGImagePropertyExifDictionary as String])

        // An uncompressed copy of the same pixels, to check the lossless JPEG tiles externally.
        if ProcessInfo.processInfo.environment["FUJIDROP_TEST_OUT"] != nil {
            var frame = try XTransDecoder.decode(raw)
            let native = ColorCleanup.clean(frame)
            frame.pixels = []
            let image = LinearImage(width: frame.width, height: frame.height, samples: .integer(native),
                                    crop: (0, 0, frame.width, frame.height), wb: frame.wb, camXYZ: frame.camXYZ,
                                    make: frame.make, model: frame.model, properties: frame.properties)
            try DNGWriter.write(image, to: out.appendingPathComponent("PLAIN.DNG"), baselineExposure: 0, preview: nil)
        }
    }
}
