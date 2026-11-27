import Foundation

/// Minimal PTP (ISO 15740) helpers for building pass-through commands and
/// decoding what comes back. Pure Foundation so it can be unit tested anywhere.
public enum PTP {
    public enum Operation: UInt16 {
        case getDeviceInfo = 0x1001
        case getDevicePropDesc = 0x1014
        case getDevicePropValue = 0x1015
        case setDevicePropValue = 0x1016
    }

    public enum Property: UInt16 {
        case dateTime = 0x5011
    }

    public enum ContainerType: UInt16 {
        case command = 1, data = 2, response = 3, event = 4
    }

    public static let headerLength = 12
    public static let responseOK: UInt16 = 0x2001

    // MARK: Command container

    /// Builds a command block: length, type, operation code, transaction ID, then up to 5 params.
    public static func commandContainer(
        _ operation: UInt16,
        transactionID: UInt32,
        params: [UInt32] = []
    ) -> Data {
        precondition(params.count <= 5, "PTP allows at most 5 parameters")
        var data = Data()
        data.appendLE(UInt32(headerLength + 4 * params.count))
        data.appendLE(ContainerType.command.rawValue)
        data.appendLE(operation)
        data.appendLE(transactionID)
        for p in params { data.appendLE(p) }
        return data
    }

    // MARK: Response container

    public struct Response: Equatable, Sendable {
        public var code: UInt16
        public var transactionID: UInt32
        public var params: [UInt32]

        public var isOK: Bool { code == PTP.responseOK }
        public var name: String { PTP.responseName(code) }
    }

    /// Parses a response container. Returns nil if it isn't a well-formed response block.
    public static func parseResponse(_ data: Data) -> Response? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength,
              let length = bytes.readLE(UInt32.self, at: 0),
              let type = bytes.readLE(UInt16.self, at: 4),
              type == ContainerType.response.rawValue,
              let code = bytes.readLE(UInt16.self, at: 6),
              let txID = bytes.readLE(UInt32.self, at: 8)
        else { return nil }
        let end = min(Int(length), bytes.count)
        var params: [UInt32] = []
        var offset = headerLength
        while offset + 4 <= end, let p = bytes.readLE(UInt32.self, at: offset) {
            params.append(p)
            offset += 4
        }
        return Response(code: code, transactionID: txID, params: params)
    }

    /// The data phase may or may not arrive wrapped in a 12-byte data container header
    /// depending on the transport layer. Strip it if present.
    public static func payload(fromDataPhase data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength,
              let length = bytes.readLE(UInt32.self, at: 0),
              let type = bytes.readLE(UInt16.self, at: 4),
              Int(length) == bytes.count,
              type == ContainerType.data.rawValue
        else { return data }
        return Data(bytes[headerLength...])
    }

    public static func responseName(_ code: UInt16) -> String {
        switch code {
        case 0x2001: return "OK"
        case 0x2002: return "General Error"
        case 0x2003: return "Session Not Open"
        case 0x2005: return "Operation Not Supported"
        case 0x200A: return "DeviceProp Not Supported"
        case 0x200F: return "Access Denied"
        case 0x2019: return "Device Busy"
        case 0x201B: return "Invalid DeviceProp Format"
        case 0x201C: return "Invalid DeviceProp Value"
        case 0x201D: return "Invalid Parameter"
        default: return String(format: "0x%04X", code)
        }
    }

    // MARK: Strings

    /// PTP string: UInt8 character count (including the null terminator), then UTF-16LE.
    /// The empty string is a single zero byte.
    public static func encodeString(_ string: String) -> Data {
        guard !string.isEmpty else { return Data([0]) }
        let units = Array(string.utf16) + [0]
        precondition(units.count <= 255, "PTP strings are limited to 255 characters")
        var data = Data([UInt8(units.count)])
        for u in units { data.appendLE(u) }
        return data
    }

    /// Decodes a PTP string at `offset`. Returns the string and the number of bytes consumed.
    public static func decodeString(_ data: Data, at offset: Int = 0) -> (String, Int)? {
        let bytes = [UInt8](data)
        guard offset < bytes.count else { return nil }
        let count = Int(bytes[offset])
        if count == 0 { return ("", 1) }
        var units: [UInt16] = []
        for i in 0..<count {
            guard let u = bytes.readLE(UInt16.self, at: offset + 1 + 2 * i) else { return nil }
            units.append(u)
        }
        if units.last == 0 { units.removeLast() }
        return (String(decoding: units, as: UTF16.self), 1 + 2 * count)
    }

    // MARK: DateTime ("YYYYMMDDThhmmss[.s][Z|±hhmm]")

    /// Parses the camera's DateTime property. Cameras usually report local time with no zone,
    /// so `timeZone` is applied unless the string carries its own.
    public static func parseDateTime(_ string: String, timeZone: TimeZone = .current) -> Date? {
        var s = Substring(string)
        var zone = timeZone
        if s.hasSuffix("Z") {
            zone = TimeZone(secondsFromGMT: 0)!
            s = s.dropLast()
        } else if s.count >= 5, let signIndex = s.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let offsetText = s[s.index(after: signIndex)...]
            if offsetText.count == 4, let hhmm = Int(offsetText) {
                let seconds = (hhmm / 100) * 3600 + (hhmm % 100) * 60
                zone = TimeZone(secondsFromGMT: s[signIndex] == "-" ? -seconds : seconds) ?? timeZone
                s = s[..<signIndex]
            }
        }
        if let dot = s.firstIndex(of: ".") { s = s[..<dot] }
        guard s.count == 15, s[s.index(s.startIndex, offsetBy: 8)] == "T" else { return nil }
        let digits = s.replacingOccurrences(of: "T", with: "")
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func field(_ start: Int, _ len: Int) -> Int {
            let a = digits.index(digits.startIndex, offsetBy: start)
            return Int(digits[a..<digits.index(a, offsetBy: len)])!
        }
        var comps = DateComponents()
        comps.year = field(0, 4); comps.month = field(4, 2); comps.day = field(6, 2)
        comps.hour = field(8, 2); comps.minute = field(10, 2); comps.second = field(12, 2)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: comps)
    }

    /// Formats a date as camera-local "YYYYMMDDThhmmss" (no zone suffix).
    public static func formatDateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    // MARK: Debug

    public static func hex(_ data: Data, limit: Int = 48) -> String {
        let shown = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? "\(shown) … (\(data.count) bytes)" : shown
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var value: T = 0
        for i in 0..<size { value |= T(self[offset + i]) << (8 * i) }
        return value
    }
}
