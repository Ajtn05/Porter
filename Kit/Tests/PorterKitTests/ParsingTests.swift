import Foundation
import Testing
@testable import PorterKit

@Suite("adb output parsing")
struct ADBParsingTests {

    @Test("Reads a device list, ignoring daemon chatter")
    func deviceList() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        R5CT30ABCDE            device usb:337641472X product:a52qnaxx model:SM_A526U device:a52q transport_id:3
        1A2B3C4D               unauthorized usb:16766976X transport_id:5
        192.168.1.44:5555      device product:redfin model:Pixel_5 device:redfin transport_id:7

        """
        let devices = ADBParsing.parseDeviceList(output)
        #expect(devices.count == 3)
        #expect(devices[0].serial == "R5CT30ABCDE")
        #expect(devices[0].readiness == .ready)
        #expect(devices[0].model == "SM A526U")
        #expect(devices[1].readiness == .unauthorized)
        #expect(devices[2].isNetworkAddress)
        #expect(devices[2].model == "Pixel 5")
    }

    @Test("Decodes stat records including sizes and modes")
    func statRecords() {
        let output = """
        41ed|4096|1714003200|/storage/emulated/0/DCIM
        81b0|5242880|1713900000|/storage/emulated/0/video.mp4
        a1ff|21|1713900000|/storage/emulated/0/link
        """
        let files = ADBParsing.parseStatRecords(output)
        #expect(files.count == 3)
        #expect(files[0].kind == .directory)
        #expect(files[1].kind == .file)
        #expect(files[1].size == 5_242_880)
        #expect(files[1].name == "video.mp4")
        #expect(files[2].kind == .symlink)
        #expect(files[1].modified == Date(timeIntervalSince1970: 1_713_900_000))
    }

    @Test("A filename containing a newline stays one entry")
    func statRecordWithNewlineInName() {
        // Newlines are legal in Android filenames, and would otherwise split
        // one file into two bogus entries.
        let output = "81b0|10|1713900000|/sdcard/two\nline.txt\n81b0|20|1713900000|/sdcard/after.txt"
        let files = ADBParsing.parseStatRecords(output)
        #expect(files.count == 2)
        #expect(files[0].path.string == "/sdcard/two\nline.txt")
        #expect(files[1].name == "after.txt")
    }

    @Test("The trailing newline of the output is not glued onto the last name")
    func statRecordsIgnoreTrailingNewline() {
        // Regression, seen on a Galaxy S22: every listing ended with a
        // directory whose name carried a stray "\n", so browsing into it looked
        // for a path that did not exist.
        let output = "41ed|4096|1714003200|/sdcard/DCIM/june\n41ed|4096|1714003200|/sdcard/DCIM/july\n"
        let files = ADBParsing.parseStatRecords(output)
        #expect(files.count == 2)
        #expect(files.map(\.name) == ["june", "july"])
        #expect(!files.contains { $0.path.string.contains("\n") })
    }

    @Test("A filename that really does end in a newline still round-trips")
    func statRecordsTrailingNewlineInName() {
        let output = "81b0|10|1714003200|/sdcard/odd\n\n"
        let files = ADBParsing.parseStatRecords(output)
        #expect(files.count == 1)
        #expect(files[0].path.string == "/sdcard/odd\n")
    }

    @Test("Reads toybox's hex superblock magic as well as a name")
    func filesystemMagics() {
        // toybox prints the raw magic; GNU coreutils prints a name.
        #expect(ADBParsing.filesystem(fromStatType: "0x65735546") == .fuse)
        #expect(ADBParsing.filesystem(fromStatType: "0xf2f52010") == .f2fs)
        #expect(ADBParsing.filesystem(fromStatType: "0xef53") == .ext4)
        #expect(ADBParsing.filesystem(fromStatType: "0x2011BAB0") == .exfat)
        #expect(ADBParsing.filesystem(fromStatType: "0x4d44") == .fat32)
        #expect(ADBParsing.filesystem(fromStatType: "f2fs") == .f2fs)
    }

    @Test("Looks through the FUSE layer to the filesystem underneath")
    func backingFilesystem() {
        let mounts = """
        /dev/block/dm-58 on /data type f2fs (rw,seclabel)
        /dev/fuse on /storage/emulated type fuse (rw,nosuid)
        /dev/block/vold/public:179,65 on /mnt/media_rw/1A2B-3C4D type exfat (rw)
        """
        // Internal storage: the FUSE mount is skipped and /data answers.
        #expect(ADBParsing.backingFilesystem(fromMountOutput: mounts, forPath: "/data/media/0") == .f2fs)
        // A card resolves to its real format, which sets the per-file limit.
        #expect(ADBParsing.backingFilesystem(fromMountOutput: mounts, forPath: "/mnt/media_rw/1A2B-3C4D") == .exfat)
        #expect(ADBParsing.backingFilesystem(fromMountOutput: mounts, forPath: "/nowhere") == .unknown)
    }

    @Test("Knows where a presented storage path really lives")
    func backingPaths() {
        #expect(ADBTransport.backingPaths(for: RemotePath("/storage/emulated/0")).first == "/data/media/0")
        #expect(ADBTransport.backingPaths(for: RemotePath("/storage/1A2B-3C4D")).first == "/mnt/media_rw/1A2B-3C4D")
        #expect(ADBTransport.backingPaths(for: RemotePath("/data/local/tmp")) == ["/data/local/tmp"])
    }

    @Test("Filenames containing the field separator survive")
    func statRecordWithPipeInName() {
        let files = ADBParsing.parseStatRecords("81b0|10|1713900000|/sdcard/a|b.txt")
        #expect(files.count == 1)
        #expect(files[0].name == "a|b.txt")
    }

    @Test("Falls back to ls -la, keeping spaces in names")
    func lsFallback() {
        let output = """
        total 96
        drwxrwx--x 4 root sdcard_rw   4096 2024-04-25 09:20 DCIM
        -rw-rw---- 1 root sdcard_rw 104857600 2024-04-20 14:05 my holiday video.mp4
        lrwxrwxrwx 1 root root         21 2024-01-01 00:00 sdcard -> /storage/self/primary
        """
        let files = ADBParsing.parseListing(output, in: RemotePath("/storage/emulated/0"))
        #expect(files.count == 3)
        #expect(files[0].kind == .directory)
        #expect(files[1].name == "my holiday video.mp4")
        #expect(files[1].size == 104_857_600)
        #expect(files[2].kind == .symlink)
        #expect(files[2].symlinkTarget == "/storage/self/primary")
    }

    @Test("Reads df, converting 1K blocks to bytes")
    func diskFree() throws {
        let output = """
        Filesystem     1K-blocks     Used Available Use% Mounted on
        /dev/block/dm-5 112000000 40000000  72000000  36% /storage/emulated
        """
        // Unwrapped rather than compared through the optional. See
        // Docs/testing-notes.md for why `#expect(optionalInt64 == someInt)`
        // reports a mismatch between two equal numbers.
        let free = try #require(ADBParsing.parseDiskFree(output))
        #expect(free.totalBytes == 112_000_000 * 1024)
        #expect(free.availableBytes == 72_000_000 * 1024)
        #expect(free.mountPoint == "/storage/emulated")
    }

    @Test("Handles a df row that toybox wrapped onto a second line")
    func diskFreeWrapped() throws {
        let output = """
        Filesystem     1K-blocks    Used Available Use% Mounted on
        /dev/block/mapper/very_long_device_name_here
                        61000000 9000000  52000000  15% /storage/emulated
        """
        let free = try #require(ADBParsing.parseDiskFree(output))
        #expect(free.availableBytes == 52_000_000 * 1024)
    }

    @Test("Maps filesystem names, which decide the 4 GB ceiling")
    func filesystemMapping() {
        #expect(ADBParsing.filesystem(fromStatType: "ext2/ext3\n") == .ext4)
        #expect(ADBParsing.filesystem(fromStatType: "msdos") == .fat32)
        #expect(ADBParsing.filesystem(fromStatType: "exfat") == .exfat)
        #expect(StorageVolume.Filesystem.fat32.maximumFileSize == 4 * 1024 * 1024 * 1024 - 1)
        #expect(StorageVolume.Filesystem.exfat.maximumFileSize == nil)
    }

    @Test("Parses getprop key/value pairs")
    func properties() {
        let output = """
        [ro.product.manufacturer]: [Google]
        [ro.product.model]: [Pixel 7]
        [ro.build.version.release]: [14]
        """
        let properties = ADBParsing.parseProperties(output)
        #expect(properties["ro.product.model"] == "Pixel 7")
        #expect(properties["ro.build.version.release"] == "14")
    }

    @Test("Reads the device timezone offset that touch -t depends on")
    func timeZoneOffset() {
        #expect(ADBTransport.timeZone(fromOffset: "+0530\n")?.secondsFromGMT() == 19800)
        #expect(ADBTransport.timeZone(fromOffset: "-0800")?.secondsFromGMT() == -28800)
        #expect(ADBTransport.timeZone(fromOffset: "garbage") == nil)
    }
}

@Suite("Remote paths")
struct RemotePathTests {

    @Test("Normalises separators and builds breadcrumbs")
    func basics() {
        let path = RemotePath("/storage/emulated/0//DCIM/")
        #expect(path.string == "/storage/emulated/0/DCIM")
        #expect(path.name == "DCIM")
        #expect(path.parent?.string == "/storage/emulated/0")
        #expect(path.breadcrumbs.count == 5)
        #expect(path.breadcrumbs.first == .root)
    }

    @Test("Knows its descendants and relative paths")
    func relationships() {
        let root = RemotePath("/sdcard/DCIM")
        let child = RemotePath("/sdcard/DCIM/Camera/IMG_0001.jpg")
        #expect(child.isDescendant(of: root))
        #expect(!root.isDescendant(of: child))
        #expect(child.relative(to: root)?.components == ["Camera", "IMG_0001.jpg"])
        #expect(child.relative(to: RemotePath("/other")) == nil)
    }

    @Test("Quotes for the shell, including embedded quotes")
    func shellQuoting() {
        // A file named  it's a "test"; rm -rf ~  must reach the device's shell
        // as data, never as syntax.
        let path = RemotePath("/sdcard/it's a \"test\"; rm -rf ~")
        #expect(path.shellQuoted == "'/sdcard/it'\\''s a \"test\"; rm -rf ~'")
        // The dangerous substring stays inside quotes, so the shell cannot act
        // on it.
        #expect(path.shellQuoted.hasPrefix("'"))
        #expect(path.shellQuoted.hasSuffix("'"))
        #expect("$(reboot)".shellQuoted == "'$(reboot)'")
    }
}

@Suite("USB interface classification")
struct USBInterfaceTests {

    @Test("Recognises MTP and ADB interfaces")
    func classification() {
        let mtp = USBInterface(interfaceClass: 6, interfaceSubclass: 1, interfaceProtocol: 1)
        let adb = USBInterface(interfaceClass: 255, interfaceSubclass: 66, interfaceProtocol: 1)
        let charging = USBInterface(interfaceClass: 255, interfaceSubclass: 255, interfaceProtocol: 255)
        #expect(mtp.isMTP && mtp.isStorageCapable)
        #expect(adb.isADB && adb.isStorageCapable)
        #expect(!charging.isStorageCapable)
    }

    @Test("Known Android vendors are recognised by ID")
    func vendors() {
        #expect(AndroidVendorIDs.manufacturer(forVendorID: 0x18D1) == "Google")
        #expect(AndroidVendorIDs.manufacturer(forVendorID: 0x04E8) == "Samsung")
        #expect(!AndroidVendorIDs.isKnownAndroidVendor(0xFFFF))
    }
}
