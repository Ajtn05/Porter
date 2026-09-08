import Foundation

/// USB vendor IDs that ship Android handsets, as published in the Android OEM
/// USB driver list.
///
/// This exists for one reason: to recognise a phone that is plugged in but
/// exposing no storage interface at all. Without a vendor list, a charge-only
/// phone is indistinguishable from a USB fan, and we would have nothing to say
/// to the user beyond an empty window.
public enum AndroidVendorIDs {
    public static let table: [Int: String] = [
        0x0502: "Acer", 0x0B05: "ASUS", 0x0489: "Foxconn", 0x04C5: "Fujitsu",
        0x091E: "Garmin-Asus", 0x18D1: "Google", 0x201E: "Haier", 0x109B: "Hisense",
        0x03F0: "HP", 0x0BB4: "HTC", 0x12D1: "Huawei", 0x24E3: "K-Touch",
        0x2116: "KT Tech", 0x0482: "Kyocera", 0x17EF: "Lenovo", 0x1004: "LG",
        0x22B8: "Motorola", 0x2A70: "OnePlus", 0x2D95: "Vivo", 0x22D9: "OPPO",
        0x0E8D: "MediaTek", 0x0FCE: "Sony", 0x04E8: "Samsung", 0x2717: "Xiaomi",
        0x2A45: "Meizu", 0x19D2: "ZTE", 0x1EBF: "Coolpad", 0x413C: "Dell",
        0x0414: "Giga-Byte", 0x1BBB: "Alcatel", 0x2C7C: "Quectel", 0x05C6: "Qualcomm",
        0x1F53: "Sharp", 0x0930: "Toshiba", 0x2916: "Yota", 0x1D4D: "Pegatron",
        0x257A: "Nubia", 0x2B0E: "TCL", 0x29A9: "Wileyfox", 0x2ACF: "Fairphone"
    ]

    public static func manufacturer(forVendorID vendorID: Int) -> String? {
        table[vendorID]
    }

    public static func isKnownAndroidVendor(_ vendorID: Int) -> Bool {
        table[vendorID] != nil
    }
}
