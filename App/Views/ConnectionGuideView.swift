import PorterKit
import SwiftUI

/// Empty state that doubles as onboarding.
///
/// Instead of reporting the readiness state, it names the change the user has
/// to make on the phone, using that manufacturer's own menu wording when the
/// manufacturer is known.
struct ConnectionGuideView: View {
    let device: Device?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                Image(systemName: illustration)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        GuideStep(number: index + 1, text: step)
                    }
                }
                .padding(18)
                .frame(maxWidth: 460, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                if showsDebuggingHint {
                    DisclosureGroup("Make transfers faster (optional)") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Turning on USB debugging lets this Mac use a faster connection that can also resume interrupted copies and verify each file. Nothing is sent anywhere; it is a setting on the phone.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(debuggingSteps.enumerated()), id: \.offset) { index, step in
                                GuideStep(number: index + 1, text: step)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                }
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - Content

    private var manufacturer: String? {
        device?.manufacturer ?? device?.usb?.vendorName
    }

    private var illustration: String {
        switch device?.readiness {
        case .none: return "cable.connector"
        case .chargingOnly: return "bolt.badge.xmark"
        case .unauthorized: return "lock.shield"
        case .locked: return "lock.iphone"
        default: return "iphone.gen3"
        }
    }

    private var title: String {
        switch device?.readiness {
        case .none:
            return "Connect an Android phone"
        case .chargingOnly:
            return "\(device?.displayName ?? "This phone") is only charging"
        case .unauthorized:
            return "Allow this Mac on your phone"
        case .locked:
            return "Unlock your phone"
        case .offline:
            return "\(device?.displayName ?? "This device") stopped responding"
        case .ready:
            return "Opening\u{2026}"
        }
    }

    private var subtitle: String {
        switch device?.readiness {
        case .none:
            return "Plug it into this Mac with a USB cable that carries data. Charge-only cables, and most cables that came with a battery pack, will not work."
        case .chargingOnly:
            return "The phone is connected, but it is not sharing its files yet. This is a setting on the phone and takes one tap."
        case .unauthorized:
            return "Your phone is asking whether to trust this computer."
        case .locked:
            return "The phone stops answering while the screen is locked, which interrupts transfers."
        case .offline:
            return "Try unplugging the cable and plugging it back in."
        case .ready:
            return ""
        }
    }

    private var steps: [String] {
        switch device?.readiness {
        case .none:
            return [
                "Use a cable that transfers data, not just power \u{2014} the one that came with the phone is a safe bet.",
                "Plug it directly into the Mac if you can. Some hubs and keyboards do not pass through enough power.",
                "Unlock the phone. It will not share files while the screen is locked."
            ]
        case .chargingOnly:
            return chargingOnlySteps
        case .unauthorized:
            return [
                "Unlock the phone.",
                "A dialog reading \u{201C}Allow USB debugging?\u{201D} will appear.",
                "Tick \u{201C}Always allow from this computer\u{201D}, then tap Allow."
            ]
        case .locked:
            return ["Unlock the phone.", "Keep the screen on while a large copy is running, or set Display timeout to a longer value."]
        case .offline:
            return ["Unplug the cable and plug it back in.", "Try a different USB port.", "If the phone is in a case, make sure the connector is fully seated."]
        case .ready:
            return []
        }
    }

    /// USB-mode wording varies by manufacturer, so match the label the phone
    /// itself shows rather than giving a generic instruction.
    private var chargingOnlySteps: [String] {
        let mode: String
        switch manufacturer?.lowercased() {
        case let value? where value.contains("samsung"):
            mode = "Transferring files / Android Auto"
        case let value? where value.contains("google"):
            mode = "File transfer / Android Auto"
        case let value? where value.contains("xiaomi") || value.contains("redmi"):
            mode = "File transfer"
        case let value? where value.contains("oneplus") || value.contains("oppo"):
            mode = "Transfer files"
        default:
            mode = "File transfer"
        }
        return [
            "Unlock the phone.",
            "Swipe down from the top to open the notification shade.",
            "Tap the notification that mentions USB \u{2014} it usually reads \u{201C}Charging this device via USB\u{201D}.",
            "Choose \u{201C}\(mode)\u{201D}.",
            "This window will update on its own within a second or two."
        ]
    }

    private var showsDebuggingHint: Bool {
        device?.transport == .mtp || device?.readiness == .chargingOnly
    }

    private var debuggingSteps: [String] {
        [
            "Open Settings \u{203A} About phone.",
            "Tap \u{201C}Build number\u{201D} seven times. It will say you are now a developer.",
            "Go back to Settings \u{203A} System \u{203A} Developer options.",
            "Turn on \u{201C}USB debugging\u{201D}, then tap Allow when this Mac asks."
        ]
    }
}

struct GuideStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
