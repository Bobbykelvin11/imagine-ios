import Foundation
import AVFoundation
import UIKit
import CoreVideo

/// Makes an MP4 on the iPhone from still images: slow zoom/pan ("Ken Burns") or a morph-style crossfade
/// between several images. Free, offline and unlimited, unlike real AI video.
enum ClipMaker {
    enum Style: String, CaseIterable, Identifiable {
        case kenBurns = "Zoom & pan"
        case morph = "Morph between images"
        var id: String { rawValue }
    }

    enum ClipError: LocalizedError {
        case writer(String)
        var errorDescription: String? { if case .writer(let s) = self { return "Couldn't make the clip: \(s)" }; return nil }
    }

    static func outputSize(for image: UIImage, longSide: CGFloat = 1280) -> CGSize {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let s = longSide / max(w, h)
        func even16(_ v: CGFloat) -> CGFloat { max(16, (v / 16).rounded() * 16) }
        return CGSize(width: even16(w * s), height: even16(h * s))
    }

    static func make(images: [UIImage], style: Style, secondsPerImage: Double, fps: Int32 = 30) async throws -> URL {
        let cgs = images.compactMap { normalized($0) }
        guard let first = images.first, !cgs.isEmpty else { throw ClipError.writer("no images") }
        let size = outputSize(for: first)
        return try await Task.detached(priority: .userInitiated) {
            try render(cgs, size: size, style: style, secondsPerImage: secondsPerImage, fps: fps)
        }.value
    }

    private static func normalized(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in image.draw(at: .zero) }.cgImage
    }

    private static func render(_ images: [CGImage], size: CGSize, style: Style, secondsPerImage: Double, fps: Int32) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw ClipError.writer("can't add video track") }
        writer.add(input)
        guard writer.startWriting() else { throw ClipError.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        let per = max(1.5, secondsPerImage)
        let total = images.count == 1 ? max(per, 3) : per * Double(images.count)
        let frameCount = Int(total * Double(fps))
        let fade = images.count > 1 ? min(1.2, per * 0.45) : 0

        for f in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let t = Double(f) / Double(fps)
            guard let pool = adaptor.pixelBufferPool else { throw ClipError.writer("no buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw ClipError.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.interpolationQuality = .high
                let idx = min(images.count - 1, Int(t / per))
                let local = (t - Double(idx) * per) / per
                draw(images[idx], in: ctx, size: size, progress: local, index: idx, style: style, alpha: 1)
                // Crossfade into the next picture near the end of this one.
                if idx + 1 < images.count, fade > 0 {
                    let into = t - (Double(idx + 1) * per - fade)
                    if into > 0 {
                        let a = smooth(into / fade)
                        draw(images[idx + 1], in: ctx, size: size, progress: 0, index: idx + 1, style: style, alpha: a)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: fps)) {
                throw ClipError.writer(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw ClipError.writer(writer.error?.localizedDescription ?? "finish failed") }
        return url
    }

    private static func smooth(_ x: Double) -> CGFloat {
        let c = max(0, min(1, x))
        return CGFloat(c * c * (3 - 2 * c))
    }

    /// Aspect-fills the image with a slow zoom and drift that changes direction per image.
    private static func draw(_ img: CGImage, in ctx: CGContext, size: CGSize, progress: Double, index: Int, style: Style, alpha: CGFloat) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let fill = max(size.width / iw, size.height / ih)
        let p = smooth(progress)
        let zoomIn = index % 2 == 0
        let amount: CGFloat = style == .kenBurns ? 0.18 : 0.08
        let zoom = 1 + amount * (zoomIn ? p : 1 - p)
        let w = iw * fill * zoom, h = ih * fill * zoom
        let dirs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let d = dirs[index % dirs.count]
        let driftX = (w - size.width) / 2 * d.0 * (p - 0.5) * 0.9
        let driftY = (h - size.height) / 2 * d.1 * (p - 0.5) * 0.9
        let rect = CGRect(x: (size.width - w) / 2 + driftX, y: (size.height - h) / 2 + driftY, width: w, height: h)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    }
}
