import AppKit
import ScreenCaptureKit

struct DisplayCapture {
    let displayIndex: Int          // 1-based, in SCShareableContent order
    let displayID: CGDirectDisplayID
    let image: CGImage
    let jpegData: Data
    let signature: [Float]         // 64×64 grayscale thumbnail for change detection
}

enum CaptureError: LocalizedError {
    case noPermission
    case encodeFailed
    var errorDescription: String? {
        switch self {
        case .noPermission: return "Screen Recording permission is required. Grant it in System Settings › Privacy & Security › Screen Recording, then relaunch Nosey."
        case .encodeFailed: return "Could not encode screenshot."
        }
    }
}

/// Captures every connected display with ScreenCaptureKit, downscaled so the longest edge fits
/// `maxEdge` pixels (the API resizes anything larger to 1568 anyway), excluding Nosey's own windows
/// and those of any app in `excludedBundleIDs`.
final class ScreenCapturer {
    var maxEdge: Int = 1568
    var jpegQuality: CGFloat = 0.75
    /// Apps whose windows are removed from the capture; what is behind them shows through.
    var excludedBundleIDs: Set<String> = []

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func captureAll() async throws -> [DisplayCapture] {
        guard ScreenCapturer.hasPermission else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let myBundle = Bundle.main.bundleIdentifier ?? ""
        let skip = excludedBundleIDs.union([myBundle]).map { $0.lowercased() }
        let excluded = content.applications.filter { skip.contains($0.bundleIdentifier.lowercased()) }
        // Where an excluded app's window sits, a labeled box is painted so the gap is not mistaken for
        // the real screen. Nosey's own windows stay unmarked. Menus, tooltips and helper windows are skipped.
        let hidden = content.windows.filter { w in
            guard let app = w.owningApplication, app.bundleIdentifier != myBundle,
                  skip.contains(app.bundleIdentifier.lowercased()) else { return false }
            return w.isOnScreen && w.windowLayer == 0 && w.frame.width >= 40 && w.frame.height >= 40
        }

        var result: [DisplayCapture] = []
        for (i, display) in content.displays.enumerated() {
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let pointScale = Double(filter.pointPixelScale)
            let longestPoints = Double(max(display.width, display.height))
            let scale = min(pointScale, Double(maxEdge) / longestPoints)
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int((Double(display.width) * scale).rounded()))
            cfg.height = max(1, Int((Double(display.height) * scale).rounded()))
            cfg.showsCursor = false
            cfg.captureResolution = .best
            var cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let boxes = hidden.filter { $0.frame.intersects(display.frame) }.map {
                (rect: $0.frame.intersection(display.frame), name: $0.owningApplication?.applicationName ?? "App")
            }
            if !boxes.isEmpty { cg = ScreenCapturer.markHidden(cg, boxes: boxes, displayFrame: display.frame) }
            guard let jpeg = ScreenCapturer.jpeg(cg, quality: jpegQuality) else { throw CaptureError.encodeFailed }
            result.append(DisplayCapture(displayIndex: i + 1,
                                         displayID: display.displayID,
                                         image: cg,
                                         jpegData: jpeg,
                                         signature: ScreenCapturer.signature(of: cg)))
        }
        return result
    }

    /// Paints a labeled gray box over each hidden window's area. `boxes` and `displayFrame` are in screen
    /// points with a top-left origin (as ScreenCaptureKit reports them); the bitmap's origin is bottom-left.
    static func markHidden(_ image: CGImage, boxes: [(rect: CGRect, name: String)], displayFrame: CGRect) -> CGImage {
        let w = image.width, h = image.height
        guard displayFrame.width > 0, displayFrame.height > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sx = Double(w) / displayFrame.width, sy = Double(h) / displayFrame.height
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for box in boxes {
            let x = (box.rect.minX - displayFrame.minX) * sx
            let top = (box.rect.minY - displayFrame.minY) * sy
            let rect = CGRect(x: x, y: Double(h) - top - box.rect.height * sy,
                              width: box.rect.width * sx, height: box.rect.height * sy)
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            ctx.setLineWidth(3)
            ctx.setLineDash(phase: 0, lengths: [12, 8])
            ctx.stroke(rect.insetBy(dx: 2, dy: 2))
            ctx.setLineDash(phase: 0, lengths: [])
            let fontSize = min(36, max(13, rect.width / 22))
            let label = NSAttributedString(string: "\(box.name) window hidden by Nosey",
                                           attributes: [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.white])
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? image
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Tiny grayscale thumbnail used to detect whether the screen changed meaningfully.
    static func signature(of image: CGImage, size: Int = 64) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: size * size)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard ok else { return [] }
        return bytes.map { Float($0) / 255 }
    }

    /// Fraction of thumbnail cells whose brightness changed noticeably.
    /// Fraction of thumbnail cells whose brightness moved by more than `cellThreshold` (0–1).
    /// 0.08 catches layout changes (window switches, scrolling); ~0.03 also catches a single typed line.
    static func changedFraction(_ a: [Float], _ b: [Float], cellThreshold: Float = 0.08) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in 0..<a.count where abs(a[i] - b[i]) > cellThreshold { n += 1 }
        return Double(n) / Double(a.count)
    }
}
