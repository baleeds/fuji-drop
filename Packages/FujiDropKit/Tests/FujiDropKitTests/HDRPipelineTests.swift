import CoreImage
import FujiDropKit
import XCTest

/// Merges a real bracket end to end. Set `FUJIDROP_TEST_BRACKET` to its RAF paths separated
/// by commas (and optionally `FUJIDROP_TEST_OUT` to keep the results); skipped otherwise.
final class HDRPipelineTests: XCTestCase {
    func testMergesRealBracket() throws {
        guard let list = ProcessInfo.processInfo.environment["FUJIDROP_TEST_BRACKET"] else {
            throw XCTSkip("Set FUJIDROP_TEST_BRACKET to comma-separated RAF paths to run this test.")
        }
        let raws = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let out = ProcessInfo.processInfo.environment["FUJIDROP_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // The camera's embedded JPEGs, as the app has them cached.
        let previews = try raws.map { raw -> URL? in
            let data = try Data(contentsOf: raw)
            guard let header = RAFHeader(data.prefix(RAFHeader.readLength)) else { return nil }
            let url = out.appendingPathComponent(raw.deletingPathExtension().lastPathComponent + "-preview.jpg")
            try data.subdata(in: header.jpegOffset..<header.jpegOffset + header.jpegLength).write(to: url)
            return url
        }

        let started = Date()
        let result = try HDRPipeline.run(raws: raws, previews: previews, name: "MERGE-HDR", into: out) { print("HDR:", $0) }
        print(String(format: "HDR total %.1f s", Date().timeIntervalSince(started)))
        result.report.forEach { print("HDR report:", $0) }

        let size = try FileManager.default.attributesOfItem(atPath: result.dng.path)[.size] as? Int ?? 0
        print("DNG \(size / 1_000_000) MB at \(result.dng.path)")
        XCTAssertGreaterThan(size, 1_000_000)
        // Apple's RAW engine (what Photos uses) reads it as a RAW.
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: result.dng))
        XCTAssertGreaterThan(filter.nativeSize.width, 4000)
        XCTAssertNotNil(filter.outputImage)
        XCTAssertNotNil(CGImageSourceCreateWithURL(result.jpeg as CFURL, nil))
    }
}
