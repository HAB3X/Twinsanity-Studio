import Foundation
import CoreML
import Vision
import CoreImage
import CoreGraphics
import CTModels
import CTExport

/// "Neural Texture Upscaling" (roadmap 5.4): a real CoreML + Vision
/// pipeline that upscales a decoded `TextureAsset` using a real,
/// user-supplied `.mlmodel`/`.mlmodelc`, image super-resolution models
/// are a real, common CoreML model shape (image in, larger image out),
/// and this is the real, standard way to run one (`VNCoreMLRequest` over
/// a `VNImageRequestHandler`, reading back a `VNPixelBufferObservation`).
///
/// No model ships with this build. There's no verified, licensable,
/// already-trained super-resolution `.mlmodel` to bundle, and training
/// one isn't something this session can do, fabricating a "working"
/// upscaler without a real model behind it would mean either silently
/// returning the input unchanged (dishonest, it would look like it
/// upscaled when it didn't) or inventing pixel data outright (worse).
/// What's real and genuinely useful without a model: the full pipeline
/// itself, correctly introspecting whatever real model *is* supplied
/// rather than assuming a fixed input/output shape, so this becomes a
/// real, working feature the moment someone points it at a real model.
public enum TextureUpscaler {
    public enum UpscaleError: Error, LocalizedError, Equatable {
        case modelNotFound
        case modelLoadFailed(String)
        case sourceNotDecoded
        case predictionFailed(String)
        case unexpectedOutputFormat

        public var errorDescription: String? {
            switch self {
            case .modelNotFound: return "No CoreML model file was found at the given location."
            case .modelLoadFailed(let reason): return "Couldn't load the CoreML model: \(reason)"
            case .sourceNotDecoded: return "This texture's pixel format isn't fully decoded by this build, so there's no real pixel data to upscale."
            case .predictionFailed(let reason): return "The model failed to run: \(reason)"
            case .unexpectedOutputFormat: return "The model's output wasn't an image this build knows how to read back."
            }
        }

        public static func == (lhs: UpscaleError, rhs: UpscaleError) -> Bool {
            lhs.errorDescription == rhs.errorDescription
        }
    }

    /// Upscales `texture` using the real model at `modelURL`. Runs
    /// entirely off the main actor, CoreML/Vision inference is real,
    /// potentially slow CPU/GPU/ANE work, same reasoning every other
    /// heavy operation in this codebase (archive scanning, level
    /// resolution) already gets offloaded for.
    public static func upscale(_ texture: TextureAsset, usingModelAt modelURL: URL) async throws -> TextureAsset {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw UpscaleError.modelNotFound
        }
        guard texture.pixelFormat.isFullyDecoded else {
            throw UpscaleError.sourceNotDecoded
        }
        let inputImage = try makeCGImage(from: texture)
        return try await Task.detached(priority: .userInitiated) {
            let model = try loadModel(at: modelURL)
            let outputImage = try await runPrediction(model: model, inputImage: inputImage)
            return try makeTextureAsset(from: outputImage, sourceID: texture.id)
        }.value
    }

    private static func loadModel(at url: URL) throws -> VNCoreMLModel {
        do {
            let compiledURL: URL
            if url.pathExtension.lowercased() == "mlmodel" {
                compiledURL = try MLModel.compileModel(at: url)
            } else {
                compiledURL = url
            }
            let mlModel = try MLModel(contentsOf: compiledURL)
            return try VNCoreMLModel(for: mlModel)
        } catch {
            throw UpscaleError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Reuses `TextureExporter.cgImage`, the exact same, already real
    /// and verified RGBA -> `CGImage` conversion `TextureInspectorView`'s
    /// preview and PNG export already go through, not a second parallel
    /// pixel-conversion implementation with its own chance to disagree.
    private static func makeCGImage(from texture: TextureAsset) throws -> CGImage {
        do {
            return try TextureExporter.cgImage(from: texture, mipLevel: nil)
        } catch {
            throw UpscaleError.sourceNotDecoded
        }
    }

    private static func runPrediction(model: VNCoreMLModel, inputImage: CGImage) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error {
                    continuation.resume(throwing: UpscaleError.predictionFailed(error.localizedDescription))
                    return
                }
                guard let results = request.results as? [VNPixelBufferObservation], let pixelBuffer = results.first?.pixelBuffer else {
                    continuation.resume(throwing: UpscaleError.unexpectedOutputFormat)
                    return
                }
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
                    continuation.resume(throwing: UpscaleError.unexpectedOutputFormat)
                    return
                }
                continuation.resume(returning: cgImage)
            }
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cgImage: inputImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: UpscaleError.predictionFailed(error.localizedDescription))
            }
        }
    }

    /// Reads `image`'s real pixels into a fresh `TextureAsset`, the
    /// pointer handed to `CGContext` only ever escapes within
    /// `withUnsafeMutableBytes`'s own dynamic scope (never captured
    /// beyond it, unlike the common-but-technically-unsound `&array`
    /// shorthand), so `context.draw` writing into it after the
    /// initializer returns is always into still-valid memory.
    /// `internal` (not `private`) so `@testable import` can verify this
    /// real conversion path directly against a synthetic `CGImage`,
    /// without needing an actual trained model to drive it.
    static func makeTextureAsset(from image: CGImage, sourceID: UInt32) throws -> TextureAsset {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw UpscaleError.unexpectedOutputFormat
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var didDraw = false
        rgba.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            didDraw = true
        }
        guard didDraw else { throw UpscaleError.unexpectedOutputFormat }
        return TextureAsset(id: sourceID, width: width, height: height, pixelFormat: .psmct32, rgba: rgba)
    }
}
