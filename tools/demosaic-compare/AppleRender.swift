// Renders crops of RAF samples with Apple's RAW pipeline, for comparing its X-Trans
// demosaic against LibRaw's Markesteijn. Run on macOS: swift AppleRender.swift crops.json out/
// Writes, per crop: <sample>-<crop>-default.png (the app's rendering, 8-bit sRGB) and
// <sample>-<crop>-neutral.png (no noise reduction, sharpening or lens correction; 16-bit linear).
import CoreImage
import Foundation

struct Crop: Decodable { let id: String; let x: Double; let y: Double }
struct Sample: Decodable { let name: String; let url: String; let crops: [Crop] }
struct Config: Decodable { let size: Int; let samples: [Sample] }

let args = CommandLine.arguments
let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let out = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let context = CIContext(options: [.cacheIntermediates: false])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

for sample in config.samples {
    let raf = out.appendingPathComponent(sample.name + ".RAF")
    if !FileManager.default.fileExists(atPath: raf.path) {
        try Data(contentsOf: URL(string: sample.url)!).write(to: raf)
    }
    for neutral in [false, true] {
        guard let filter = CIRAWFilter(imageURL: raf) else { fatalError("cannot decode \(sample.name)") }
        if neutral {
            filter.luminanceNoiseReductionAmount = 0
            filter.colorNoiseReductionAmount = 0
            filter.sharpnessAmount = 0
            filter.contrastAmount = 0
            filter.detailAmount = 0
            filter.localToneMapAmount = 0
            filter.boostAmount = 0
            filter.isLensCorrectionEnabled = false
        }
        guard let image = filter.outputImage else { fatalError("no output \(sample.name)") }
        let e = image.extent
        print("\(sample.name) neutral=\(neutral) extent=\(e) moire=\(filter.moireReductionAmount)")
        for crop in sample.crops {
            let s = CGFloat(config.size)
            // Core Image's origin is bottom-left; crop fractions are from the top-left.
            let cx = e.minX + e.width * crop.x, cy = e.maxY - e.height * crop.y
            let rect = CGRect(x: (cx - s / 2).rounded(), y: (cy - s / 2).rounded(), width: s, height: s)
                .intersection(e)
            let file = out.appendingPathComponent("\(sample.name)-\(crop.id)-\(neutral ? "neutral" : "default").png")
            try context.writePNGRepresentation(of: image.cropped(to: rect), to: file,
                                               format: neutral ? .RGBA16 : .RGBA8,
                                               colorSpace: neutral ? linear : sRGB)
        }
    }
    try FileManager.default.removeItem(at: raf)
}
