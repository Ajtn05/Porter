import Foundation
import Testing
@testable import PorterKit

@Suite("Filename sanitizing")
struct FilenameSanitizerTests {

    @Test("Replaces the colon Finder would render as a slash")
    func colonToMac() throws {
        let sanitizer = FilenameSanitizer(destination: .macOS)
        let (name, change) = sanitizer.sanitize("Meeting: notes.txt")
        #expect(name == "Meeting\u{2236} notes.txt")
        let reported = try #require(change)
        #expect(reported.original == "Meeting: notes.txt")
        #expect(reported.reason.contains("Finder"))
    }

    @Test("Leaves ordinary names completely alone")
    func passthrough() {
        for destination in [FilenameSanitizer.Destination.macOS, .androidPOSIX, .androidFAT] {
            let (name, change) = FilenameSanitizer(destination: destination).sanitize("IMG_0421.jpg")
            #expect(name == "IMG_0421.jpg")
            #expect(change == nil)
        }
    }

    @Test("Strips characters FAT cards reject")
    func fatIllegalCharacters() throws {
        let sanitizer = FilenameSanitizer(destination: .androidFAT)
        let (name, change) = sanitizer.sanitize("report:v2?<final>.txt")
        #expect(name == "report_v2__final_.txt")
        #expect(change != nil)
    }

    @Test("Fixes FAT names ending in a space or a period")
    func fatTrailingCharacters() {
        let sanitizer = FilenameSanitizer(destination: .androidFAT)
        #expect(sanitizer.sanitize("notes.").name == "notes")
        #expect(sanitizer.sanitize("draft ").name == "draft")
    }

    @Test("Escapes reserved DOS device names")
    func fatReservedNames() {
        let sanitizer = FilenameSanitizer(destination: .androidFAT)
        #expect(sanitizer.sanitize("CON.txt").name == "_CON.txt")
        #expect(sanitizer.sanitize("aux").name == "_aux")
        #expect(sanitizer.sanitize("console.txt").name == "console.txt")
    }

    @Test("A slash cannot survive into an Android filename")
    func slashOnAndroid() {
        let sanitizer = FilenameSanitizer(destination: .androidPOSIX)
        #expect(sanitizer.sanitize("06/2024 receipts").name == "06_2024 receipts")
    }

    @Test("Shortens over-long names but keeps the extension")
    func longNames() throws {
        let sanitizer = FilenameSanitizer(destination: .macOS)
        let long = String(repeating: "é", count: 300) + ".jpeg"   // 2 bytes per é
        let (name, change) = sanitizer.sanitize(long)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".jpeg"))
        #expect(try #require(change).reason.contains("255"))
    }

    @Test("Reports every change made along a path")
    func pathComponents() {
        let sanitizer = FilenameSanitizer(destination: .macOS)
        let (components, changes) = sanitizer.sanitize(components: ["DCIM", "9:16 clips", "take:1.mp4"])
        #expect(components[0] == "DCIM")
        #expect(changes.count == 2)
    }
}

@Suite("Conflict naming")
struct ConflictNamingTests {

    @Test("Numbers copies the way Finder does")
    func sequence() {
        #expect(ConflictNaming.uniqueName(for: "photo.jpg", existing: []) == "photo.jpg")
        #expect(ConflictNaming.uniqueName(for: "photo.jpg", existing: ["photo.jpg"]) == "photo 2.jpg")
        #expect(ConflictNaming.uniqueName(for: "photo.jpg", existing: ["photo.jpg", "photo 2.jpg"]) == "photo 3.jpg")
        #expect(ConflictNaming.uniqueName(for: "photo 2.jpg", existing: ["photo 2.jpg"]) == "photo 3.jpg")
        #expect(ConflictNaming.uniqueName(for: "README", existing: ["README"]) == "README 2")
    }
}

@Suite("Storage volumes")
struct StorageVolumeTests {

    @Test("Two volumes with the same name are still told apart")
    func disambiguation() {
        let volumes = [
            StorageVolume(id: "a", rawName: "SD card", rootPath: RemotePath("/storage/1A2B-3C4D"),
                          totalBytes: 32_000_000_000, isRemovable: true),
            StorageVolume(id: "b", rawName: "SD card", rootPath: RemotePath("/storage/5E6F-7A8B"),
                          totalBytes: 256_000_000_000, isRemovable: true)
        ].disambiguated()

        #expect(volumes[0].displayName != volumes[1].displayName)
        #expect(volumes[0].displayName.contains("SD card"))
        #expect(Set(volumes.map(\.displayName)).count == 2)
    }

    @Test("Identical names and identical capacities fall back to the mount path")
    func disambiguationByPath() {
        let volumes = [
            StorageVolume(id: "a", rawName: "SD card", rootPath: RemotePath("/storage/AAAA-1111"),
                          totalBytes: 64_000_000_000, isRemovable: true),
            StorageVolume(id: "b", rawName: "SD card", rootPath: RemotePath("/storage/BBBB-2222"),
                          totalBytes: 64_000_000_000, isRemovable: true)
        ].disambiguated()

        #expect(volumes[0].displayName.contains("/storage/AAAA-1111"))
        #expect(Set(volumes.map(\.displayName)).count == 2)
    }

    @Test("A single volume keeps its plain name")
    func singleVolumeUnchanged() {
        let volumes = [StorageVolume(id: "a", rawName: "Internal storage",
                                     rootPath: RemotePath("/storage/emulated/0"))].disambiguated()
        #expect(volumes[0].displayName == "Internal storage")
    }
}

@Suite("Checksums")
struct ChecksumTests {

    @Test("Matches the published SHA-256 vectors")
    func vectors() throws {
        #expect(sha256(Data()).value == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(sha256(Data("abc".utf8)).value == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Chunked hashing of a file equals hashing it whole")
    func fileHashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("porter-hash-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = makePayload(5_000_000, seed: 41)
        try payload.write(to: url)

        // A small chunk size forces many rounds through the incremental path.
        let hashed = try ChecksumService.hashLocalFile(at: url, chunkSize: 7919)
        #expect(hashed == sha256(payload))
    }

    @Test("Hashes only the prefix a resume has actually written")
    func prefixHashing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("porter-hash-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = makePayload(100_000, seed: 43)
        try payload.write(to: url)

        let prefix = try ChecksumService.hashLocalFile(at: url, upTo: 1000)
        #expect(prefix == sha256(payload.subdata(in: 0..<1000)))
    }

    @Test("Reads sha256sum and md5sum output from the device")
    func sumParsing() throws {
        let line = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  /sdcard/my file.txt\n"
        let parsed = try #require(ChecksumService.parseSumOutput(line, algorithm: .sha256))
        #expect(parsed.value == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // A hash of the wrong length for the algorithm must be rejected.
        #expect(ChecksumService.parseSumOutput("deadbeef  /sdcard/x", algorithm: .sha256) == nil)
        #expect(ChecksumService.parseSumOutput("sha256sum: not found", algorithm: .sha256) == nil)
        #expect(ChecksumService.parseSumOutput(
            "d41d8cd98f00b204e9800998ecf8427e  /sdcard/x", algorithm: .md5) != nil)
    }
}

@Suite("Byte formatting")
struct ByteFormatTests {

    @Test("Durations read the way a person would say them")
    func durations() {
        #expect(ByteFormat.duration(12) == "12s")
        #expect(ByteFormat.duration(243) == "4m 03s")
        #expect(ByteFormat.duration(4_920) == "1h 22m")
        #expect(ByteFormat.duration(.infinity) == "—")
    }

    @Test("A zero or unknown rate shows a dash, not 0 B/s")
    func rates() {
        #expect(ByteFormat.rate(0) == "—")
        #expect(ByteFormat.rate(.nan) == "—")
        #expect(ByteFormat.rate(50_000_000).hasSuffix("/s"))
    }
}
