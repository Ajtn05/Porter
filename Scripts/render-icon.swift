import AppKit
import WebKit

/// Rasterises Branding/porter-icon.svg into a set of PNGs, one per requested size.
///
/// Each argument after the SVG and the output directory is `name:pixels`.
///
/// WebKit does the rasterising because it is the engine `qlmanage -t` used, and
/// so the artwork is unchanged from what that produced - except that qlmanage
/// composites its thumbnail onto opaque white, which baked a white square
/// behind the rounded tile in the Dock and Finder. AppKit's own SVG reader
/// renders with transparency but ignores `feDropShadow`, dropping the icon's
/// shadow, so it is not used either.
///
/// The sizes are reduced from one 1024px master rather than rendered
/// individually, which gives better small sizes, and the reduction is done in
/// CoreGraphics: it composites premultiplied, whereas resizing straight alpha
/// averages the transparent pixels' black into the rounded corners and rings
/// the tile with a dark fringe.

let masterSide = 1024

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("render-icon: " + message + "\n").utf8))
    exit(1)
}

struct Output {
    let url: URL
    let side: Int
}

final class Renderer: NSObject, WKNavigationDelegate {
    let outputs: [Output]

    init(outputs: [Output]) {
        self.outputs = outputs
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        // The gradients and the shadow filter are not always composited by the
        // time didFinish lands, and snapshotting early yields a bare tile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            webView.takeSnapshot(with: configuration) { image, error in
                guard let master = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    fail("snapshot failed: \(error.map(String.init(describing:)) ?? "no image")")
                }
                for output in self.outputs {
                    self.write(master, to: output)
                }
                print("wrote \(self.outputs.count) PNGs")
                exit(0)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("render failed: \(error)")
    }

    /// Reduces `master` to `output.side` square pixels and writes it as a PNG.
    ///
    /// The snapshot arrives at the display's backing scale, so a 2x screen
    /// returns twice the requested pixels; drawing into a bitmap of an explicit
    /// size pins the result whatever machine the script runs on.
    private func write(_ master: CGImage, to output: Output) {
        guard let context = CGContext(data: nil, width: output.side, height: output.side,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fail("cannot allocate \(output.side)x\(output.side) bitmap")
        }
        context.interpolationQuality = .high
        context.draw(master, in: CGRect(x: 0, y: 0, width: output.side, height: output.side))
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fail("cannot encode \(output.url.lastPathComponent)")
        }
        do { try png.write(to: output.url) } catch { fail("cannot write \(output.url.path): \(error)") }
    }
}

guard CommandLine.arguments.count >= 4 else {
    fail("usage: render-icon.swift <input.svg> <output-directory> <name:pixels>...")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let outputs: [Output] = CommandLine.arguments.dropFirst(3).map { argument in
    let parts = argument.split(separator: ":")
    guard parts.count == 2, let side = Int(parts[1]), side > 0, side <= masterSide else {
        fail("expected <name:pixels> with pixels in 1...\(masterSide), got '\(argument)'")
    }
    return Output(url: directory.appendingPathComponent("\(parts[0]).png"), side: side)
}
guard let svg = try? String(contentsOf: source, encoding: .utf8) else {
    fail("cannot read \(source.path)")
}
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(directory.path): \(error)")
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Laid out at the master size in points rather than scaled afterwards, so the
// stroke widths and the shadow blur resolve against the full-size geometry.
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: masterSide, height: masterSide),
                        configuration: WKWebViewConfiguration())
// KVC because the AppKit WKWebView exposes no public transparent-background
// setting; without it the snapshot arrives on opaque white.
webView.setValue(false, forKey: "drawsBackground")
let renderer = Renderer(outputs: outputs)
webView.navigationDelegate = renderer
webView.loadHTMLString("""
<html><head><meta charset="utf-8"><style>
html, body { margin: 0; padding: 0; background: transparent; }
svg { display: block; width: \(masterSide)px; height: \(masterSide)px; }
</style></head><body>\(svg)</body></html>
""", baseURL: nil)

DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fail("timed out rendering \(source.path)") }
application.run()
