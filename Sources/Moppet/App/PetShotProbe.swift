import AppKit
import SceneKit

/// `--probe-pet-shot <png> [width height]`: renders the procedural SceneKit
/// pet into a transparent PNG offscreen.
///
/// Same rationale as `PageRenderProbe`: a terminal-launched binary usually
/// lacks screen-recording permission, and `PageRenderProbe` cannot host a
/// SceneKit view (the Metal layer draws nothing into `cacheDisplay`).
/// `SCNView.snapshot()` renders through the scene's own renderer instead, so
/// no visible window and no permission are needed. The setup mirrors
/// `MoleSceneView.makeNSView` minus the interaction delegate.
@MainActor
enum PetShotProbe {

    static func run(outputPath: String, width: CGFloat = 460, height: CGFloat = 540) {
        let puppet = MolePuppet()
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.scene = puppet.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.isPlaying = true
        PetSceneBridge.shared.puppet = puppet

        // The idle loop blinks at random moments; sample a few frames and
        // keep the one with the most dark eye-band rows (i.e. eyes open) so
        // the shot doesn't catch a blink.
        var best: CGImage?
        var bestOpenness = -1
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            var rect = CGRect.zero
            guard let image = view.snapshot()
                .cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let openness = estimateEyeOpenness(image) else { continue }
            if openness > bestOpenness {
                bestOpenness = openness
                best = image
            }
        }
        guard let best, let png = NSBitmapImageRep(cgImage: best)
            .representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("probe-pet-shot: render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(
                Data("probe-pet-shot: write failed — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("probe-pet-shot: \(best.width)x\(best.height) → \(outputPath)")
        exit(0)
    }

    /// Rough blink detector: open eyes are dark blobs inside the head band;
    /// a blink collapses them. Counts mid rows of the upper-middle band that
    /// contain a dark pixel. Not science — just enough to prefer an
    /// open-eyed frame when every frame is otherwise identical.
    private static func estimateEyeOpenness(_ image: CGImage) -> Int? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var darkRows = 0
        for y in stride(from: h * 55 / 100, to: h * 75 / 100, by: 2) {
            for x in stride(from: w * 30 / 100, to: w * 70 / 100, by: 2) {
                let i = (y * w + x) * 4
                if buf[i] < 90 && buf[i + 1] < 90 && buf[i + 2] < 90 {
                    darkRows += 1
                    break
                }
            }
        }
        return darkRows
    }
}
