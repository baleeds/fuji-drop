import Foundation

/// Lossless JPEG (ITU T.81 process 14, "LJ92") encoder for DNG tiles: Compression 7, the
/// compression every DNG reader supports (camera DNGs and ProRAW use it). Core Image doesn't
/// decode Deflate in DNGs, so this is how 16-bit DNG saves stay near half size.
///
/// One scan with all components interleaved, predictor 1 (the pixel to the left; the pixel
/// above at the start of a row), and an optimal Huffman table per tile shared by the
/// components.
public enum LosslessJPEG {
    /// Encodes `height` rows of `width` pixels, `components` interleaved 16-bit samples each.
    public static func encode(_ samples: UnsafeBufferPointer<UInt16>, width: Int, height: Int,
                              components: Int, precision: Int = 16) -> Data {
        precondition(samples.count >= width * height * components && (1...4).contains(components))
        // Pass 1: differences → categories (SSSS), and their frequencies.
        let n = width * height * components
        var diffs = [Int32](repeating: 0, count: n)
        var freq = [Int](repeating: 0, count: 17)
        let half = Int32(1) << (precision - 1)
        let modulus = Int32(1) << precision
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<components {
                    let i = (y * width + x) * components + c
                    let pred: Int32
                    if x > 0 {
                        pred = Int32(samples[i - components])
                    } else if y > 0 {
                        pred = Int32(samples[i - width * components])
                    } else {
                        pred = half
                    }
                    // Differences are modulo 2^P, read as signed.
                    var d = (Int32(samples[i]) - pred) % modulus
                    if d >= half { d -= modulus } else if d < -half { d += modulus }
                    diffs[i] = d
                    freq[category(d)] += 1
                }
            }
        }
        let table = HuffmanTable(frequencies: freq)

        var out = Data()
        out.reserveCapacity(n * 2)
        out.append(contentsOf: [0xFF, 0xD8]) // SOI
        // DHT: one DC-class table, id 0.
        let dht: [UInt8] = [0x00] + table.counts.map(UInt8.init) + table.symbols.map(UInt8.init)
        segment(&out, 0xC4, dht)
        // SOF3: precision, lines, samples per line, components (1:1 sampling, no quantization).
        var sof: [UInt8] = [UInt8(precision), UInt8(height >> 8), UInt8(height & 0xFF),
                            UInt8(width >> 8), UInt8(width & 0xFF), UInt8(components)]
        for c in 0..<components { sof += [UInt8(c + 1), 0x11, 0] }
        segment(&out, 0xC3, sof)
        // SOS: all components, table 0, predictor 1, point transform 0.
        var sos: [UInt8] = [UInt8(components)]
        for c in 0..<components { sos += [UInt8(c + 1), 0x00] }
        sos += [1, 0, 0]
        segment(&out, 0xDA, sos)

        var bits = BitWriter()
        for d in diffs {
            let s = category(d)
            bits.write(table.codes[s], count: table.lengths[s])
            // SSSS 16 (difference −32768) has no extra bits.
            if s > 0, s < 16 {
                let v = d > 0 ? d : d - 1 + (Int32(1) << s)
                bits.write(UInt32(v) & ((1 << s) - 1), count: s)
            }
        }
        bits.flush()
        out.append(contentsOf: bits.bytes)
        out.append(contentsOf: [0xFF, 0xD9]) // EOI
        return out
    }

    /// SSSS: bits needed for |d| (0 for d = 0).
    @inline(__always) static func category(_ d: Int32) -> Int {
        d == 0 ? 0 : 32 - Int(UInt32(abs(d)).leadingZeroBitCount)
    }

    private static func segment(_ out: inout Data, _ marker: UInt8, _ body: [UInt8]) {
        let length = body.count + 2
        out.append(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)])
        out.append(contentsOf: body)
    }

    /// Huffman codes limited to 16 bits, built as in T.81 Annex K.2 (code lengths from
    /// frequencies with a reserved symbol so no code is all ones, then length limiting).
    struct HuffmanTable {
        /// Number of codes of each length 1…16.
        var counts = [Int](repeating: 0, count: 16)
        /// Symbols in code order.
        var symbols: [Int] = []
        var codes = [UInt32](repeating: 0, count: 17)
        var lengths = [Int](repeating: 0, count: 17)

        init(frequencies: [Int]) {
            // Annex K.2: 256 is the reserved symbol (frequency 1).
            var freq = frequencies + [1]
            let count = freq.count
            var size = [Int](repeating: 0, count: count)
            var others = [Int](repeating: -1, count: count)
            while true {
                // The two least frequent (ties: the higher symbol), v1 then v2.
                var v1 = -1, v2 = -1
                for i in 0..<count where freq[i] > 0 {
                    if v1 < 0 || freq[i] <= freq[v1] { v1 = i }
                }
                for i in 0..<count where freq[i] > 0 && i != v1 {
                    if v2 < 0 || freq[i] <= freq[v2] { v2 = i }
                }
                guard v2 >= 0 else { break }
                freq[v1] += freq[v2]
                freq[v2] = 0
                size[v1] += 1
                var j = v1
                while others[j] >= 0 { j = others[j]; size[j] += 1 }
                others[j] = v2
                size[v2] += 1
                j = v2
                while others[j] >= 0 { j = others[j]; size[j] += 1 }
            }
            var bits = [Int](repeating: 0, count: 33)
            for s in size where s > 0 { bits[s] += 1 }
            // Annex K.3: limit lengths to 16.
            var i = 32
            while i > 16 {
                while bits[i] > 0 {
                    var j = i - 2
                    while bits[j] == 0 { j -= 1 }
                    bits[i] -= 2
                    bits[i - 1] += 1
                    bits[j + 1] += 2
                    bits[j] -= 1
                }
                i -= 1
            }
            // Drop the reserved symbol's code (the longest).
            i = 16
            while bits[i] == 0 { i -= 1 }
            bits[i] -= 1
            counts = Array(bits[1...16])
            // Symbols by length, then by value (the reserved symbol excluded).
            for length in 1...32 {
                for s in 0..<frequencies.count where size[s] == length { symbols.append(s) }
            }
            // Canonical codes in that order, using the limited lengths.
            var code: UInt32 = 0, k = 0
            for length in 1...16 {
                for _ in 0..<counts[length - 1] {
                    let s = symbols[k]
                    codes[s] = code
                    lengths[s] = length
                    code += 1
                    k += 1
                }
                code <<= 1
            }
        }
    }

    /// MSB-first bit writer with JPEG byte stuffing (0xFF → 0xFF 0x00).
    struct BitWriter {
        var bytes: [UInt8] = []
        private var buffer: UInt64 = 0
        private var count = 0

        mutating func write(_ value: UInt32, count n: Int) {
            guard n > 0 else { return }
            buffer = buffer << UInt64(n) | UInt64(value & UInt32((UInt64(1) << UInt64(n)) - 1))
            count += n
            while count >= 8 {
                count -= 8
                let byte = UInt8((buffer >> UInt64(count)) & 0xFF)
                bytes.append(byte)
                if byte == 0xFF { bytes.append(0) }
            }
        }

        /// Pads the last byte with ones.
        mutating func flush() {
            if count > 0 { write((1 << (8 - count)) - 1, count: 8 - count) }
        }
    }
}
