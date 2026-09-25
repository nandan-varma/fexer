import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct RenderRecipe: Sendable {
    var edit = EditRecipe()
    var styleCube: CubeLUT?
    var adjustmentCube: CubeLUT?
}

/// Stateless filter graph builder. Each invocation owns its CIFilters; no shared mutable filters.
enum ImagePipeline {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    // iPhone HEIC capture is Display P3 (wider than sRGB); using it as the *working* space means
    // filter math never clips real sensor gamut during editing, regardless of final output
    // format. `colorSpace` (sRGB) stays separate and unchanged: applyCube's colorCubeWithColorSpace
    // filter uses it to say what space the .cube LUT's own values were authored in — a LUT-
    // correctness concern, not an output-gamut one — and JPEG/thumbnail output still wants sRGB
    // for universal compatibility. Only HEIF export (this app's default, and the format actually
    // designed for wide gamut) uses wideColorSpace for its final encoding.
    static let wideColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? colorSpace
    static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: wideColorSpace])

    static func apply(_ input: CIImage, recipe: RenderRecipe, geometry: Bool = true) -> CIImage {
        let state = recipe.edit.validated
        var image = input
        if let cube = recipe.styleCube, state.intensity > 0 {
            let styled = applyCube(cube, to: image)
            let blend = CIFilter.dissolveTransition()
            blend.inputImage = image
            blend.targetImage = styled
            blend.time = Float(state.intensity)
            image = blend.outputImage ?? image
        }
        if state.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": state.exposure]) }
        if state.highlights != 0 || state.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - state.highlights * 0.5, "inputShadowAmount": state.shadows
            ])
        }
        if state.contrast != 0 || state.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1 + state.contrast, "inputSaturation": 1 + state.saturation
            ])
        }
        if state.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": state.vibrance]) }
        if state.warmth != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - state.warmth * 2500, y: 0)
            ])
        }
        if let cube = recipe.adjustmentCube { image = applyCube(cube, to: image) }
        if let cube = state.importedCube, cube.isValid { image = applyCube(cube, to: image) }
        if state.sharpness != 0 { image = image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": state.sharpness]) }
        if state.vignette != 0 {
            image = image.applyingFilter("CIVignette", parameters: ["inputIntensity": state.vignette * 1.5, "inputRadius": 1])
        }
        guard geometry else { return image }
        return applyGeometry(image, state: state)
    }

    static func applyCube(_ cube: CubeLUT, to image: CIImage) -> CIImage {
        guard cube.isValid else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(cube.dimension)
        filter.cubeData = cube.rgba
        filter.colorSpace = colorSpace
        return filter.outputImage ?? image
    }

    static func applyGeometry(_ input: CIImage, state: EditRecipe) -> CIImage {
        var image = input
        if state.quarterTurns != 0 { image = image.transformed(by: .init(rotationAngle: Double(state.quarterTurns) * .pi / 2)) }
        image = normalized(image)
        if state.flipped { image = normalized(image.transformed(by: .init(scaleX: -1, y: 1))) }
        if state.straighten != 0 {
            let radians = state.straighten * .pi / 180
            let safeSize = CropGeometry.straightenedSize(image.extent.size, radians: radians)
            image = image.transformed(by: .init(rotationAngle: radians))
            image = image.cropped(to: CGRect(x: image.extent.midX - safeSize.width / 2,
                                             y: image.extent.midY - safeSize.height / 2,
                                             width: safeSize.width, height: safeSize.height))
        }
        let aspect: Double? = state.ratio == .original ? nil :
            (image.extent.width > image.extent.height ? 1 / state.ratio.portraitAspect : state.ratio.portraitAspect)
        image = image.cropped(to: CropGeometry.crop(in: image.extent, aspect: aspect, zoom: state.cropZoom, x: state.cropX, y: state.cropY))
        return normalized(image)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
