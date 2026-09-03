import AppKit
import ScreenCaptureKit

struct DisplayCapture {
    let displayIndex: Int          // 1-based, in SCShareableContent order
    let displayID: CGDirectDisplayID
    let image: CGImage
    let jpegData: Data
    let signature: [Float]         // 32×32 grayscale thumbnail for change detection
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
/// `maxEdge` pixels (the API resizes anything larger to 1568 anyway), excluding Nosey's own windows.
final class ScreenCapturer {
    var maxEdge: Int = 1568
    var jpegQuality: CGFloat = 0.75

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func captureAll() async throws -> [DisplayCapture] {
        guard ScreenCapturer.hasPermission else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let myBundle = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == myBundle }

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
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard let jpeg = ScreenCapturer.jpeg(cg, quality: jpegQuality) else { throw CaptureError.encodeFailed }
            result.append(DisplayCapture(displayIndex: i + 1,
                                         displayID: display.displayID,
                                         image: cg,
                                         jpegData: jpeg,
                                         signature: ScreenCapturer.signature(of: cg)))
        }
        return result
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Tiny grayscale thumbnail used to detect whether the screen changed meaningfully.
    static func signature(of image: CGImage, size: Int = 32) -> [Float] {
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
    static func changedFraction(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in 0..<a.count where abs(a[i] - b[i]) > 0.08 { n += 1 }
        return Double(n) / Double(a.count)
    }
}
