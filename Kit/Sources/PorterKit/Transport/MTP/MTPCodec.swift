import Foundation

/// Little-endian reader for the datasets that arrive in a PTP data phase.
///
/// Every read is bounds-checked and every failure names the field it was
/// reading. A malformed dataset is a normal event rather than a bug: vendors
/// ship their own MTP stacks, several of them truncate datasets they consider
/// optional, and one short read must not take down a browse of the whole phone.
public struct MTPReader {
    private let bytes: [UInt8]
    private var index = 0

    public init(_ data: Data) { self.bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - index }
    public var isAtEnd: Bool { remaining <= 0 }

    private mutating func take(_ count: Int, _ field: String) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else {
            throw TransferError.protocolError(
                "ran out of bytes reading \(field): wanted \(count), \(remaining) left")
        }
        defer { index += count }
        return bytes[index ..< index + count]
    }

    public mutating func uint8(_ field: String = "a byte") throws -> UInt8 {
        try take(1, field).first!
    }

    public mutating func uint16(_ field: String = "a 16-bit field") throws -> UInt16 {
        let slice = try take(2, field)
        var value: UInt16 = 0
        for (shift, byte) in slice.enumerated() { value |= UInt16(byte) << (8 * shift) }
        return value
    }

    public mutating func uint32(_ field: String = "a 32-bit field") throws -> UInt32 {
        let slice = try take(4, field)
        var value: UInt32 = 0
        for (shift, byte) in slice.enumerated() { value |= UInt32(byte) << (8 * shift) }
        return value
    }

    public mutating func uint64(_ field: String = "a 64-bit field") throws -> UInt64 {
        let slice = try take(8, field)
        var value: UInt64 = 0
        for (shift, byte) in slice.enumerated() { value |= UInt64(byte) << (8 * shift) }
        return value
    }

    public mutating func skip(_ count: Int, _ field: String = "padding") throws {
        _ = try take(count, field)
    }

    /// A PTP string: one byte giving the length in UTF-16 code units *including*
    /// the terminating NUL, then that many code units.
    ///
    /// A length of zero means an empty string and is followed by nothing at all,
    /// not by a NUL. Getting that wrong shifts every subsequent field in the
    /// dataset by two bytes, which is how a phone with one unnamed volume ends
    /// up reporting a nonsense capacity.
    public mutating func string(_ field: String = "a string") throws -> String {
        let units = Int(try uint8("\(field) length"))
        guard units > 0 else { return "" }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(units)
        for _ in 0 ..< units { codeUnits.append(try uint16(field)) }
        // The NUL is part of the declared length. Surrogate pairs are two code
        // units and the length counts both, so decoding the run as UTF-16
        // rather than per character is what keeps an emoji in a filename intact.
        if codeUnits.last == 0 { codeUnits.removeLast() }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    /// A PTP array: a 32-bit element count followed by the elements.
    ///
    /// The count is checked against the bytes actually left before anything is
    /// allocated, so a corrupt length cannot ask for a gigabyte of memory.
    public mutating func uint16Array(_ field: String = "an array") throws -> [UInt16] {
        let count = Int(try uint32("\(field) count"))
        guard count * 2 <= remaining else {
            throw TransferError.protocolError(
                "\(field) claims \(count) entries but only \(remaining) bytes remain")
        }
        return try (0 ..< count).map { _ in try uint16(field) }
    }

    public mutating func uint32Array(_ field: String = "an array") throws -> [UInt32] {
        let count = Int(try uint32("\(field) count"))
        guard count * 4 <= remaining else {
            throw TransferError.protocolError(
                "\(field) claims \(count) entries but only \(remaining) bytes remain")
        }
        return try (0 ..< count).map { _ in try uint32(field) }
    }
}

/// Little-endian writer for the datasets sent in a command or data phase.
public struct MTPWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var data: Data { Data(bytes) }
    public var count: Int { bytes.count }

    public mutating func uint8(_ value: UInt8) { bytes.append(value) }

    public mutating func uint16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func uint32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    public mutating func uint64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// Appends bytes that are already encoded, such as a container header.
    public mutating func raw(_ data: Data) { bytes.append(contentsOf: data) }

    public mutating func zeros(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: count))
    }

    /// Writes a PTP string, NUL included in the declared length.
    ///
    /// The length field is a single byte, so 255 code units is the hard ceiling
    /// and 254 is the most a name can carry. Truncation stops on a Character
    /// boundary: cutting a surrogate pair in half produces a filename Android
    /// will reject outright, which is a worse failure than a shortened name.
    public mutating func string(_ value: String) {
        guard !value.isEmpty else {
            uint8(0)
            return
        }
        var codeUnits = Array(value.utf16)
        if codeUnits.count > 254 {
            var truncated = ""
            for character in value {
                if truncated.utf16.count + character.utf16.count > 254 { break }
                truncated.append(character)
            }
            codeUnits = Array(truncated.utf16)
        }
        uint8(UInt8(codeUnits.count + 1))
        for unit in codeUnits { uint16(unit) }
        uint16(0)
    }
}

/// The PTP date string, `YYYYMMDDThhmmss` with optional fraction and zone.
///
/// Android usually omits the zone, and the spec says an unmarked timestamp is
/// the device's local time. There is no way to learn that zone over MTP, so the
/// caller supplies one; the app passes the Mac's, which is right whenever the
/// phone and the Mac are in the same place and wrong by a whole-hour offset when
/// they are not. That is a display-only error, and it is the reason
/// `supportsMtimePreservation` is false for this transport.
public enum MTPDate {
    public static func parse(_ text: String, deviceTimeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 15 else { return nil }
        let characters = Array(trimmed)
        guard characters[8] == "T" else { return nil }

        func number(_ range: Range<Int>) -> Int? { Int(String(characters[range])) }
        guard let year = number(0 ..< 4), let month = number(4 ..< 6), let day = number(6 ..< 8),
              let hour = number(9 ..< 11), let minute = number(11 ..< 13),
              let second = number(13 ..< 15) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var zone = deviceTimeZone
        let suffix = String(characters[15...])
            .drop { $0 == "." || $0.isNumber }   // the optional tenths of a second
        if suffix.hasPrefix("Z") {
            zone = TimeZone(secondsFromGMT: 0)!
        } else if let sign = suffix.first, sign == "+" || sign == "-", suffix.count >= 5 {
            let digits = Array(suffix.dropFirst())
            if let hours = Int(String(digits[0 ..< 2])), let minutes = Int(String(digits[2 ..< 4])) {
                let magnitude = hours * 3600 + minutes * 60
                zone = TimeZone(secondsFromGMT: sign == "-" ? -magnitude : magnitude) ?? deviceTimeZone
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components)
    }

    public static func format(_ date: Date, deviceTimeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = deviceTimeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
