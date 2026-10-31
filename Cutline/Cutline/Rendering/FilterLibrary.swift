import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Core Image implementations of presets, adjustments, chroma key and
/// transitions. Everything here is thread-safe and used by the compositor.
enum FilterLibrary {
    // MARK: Effects

    static func apply(_ effects: ClipEffects, to image: CIImage, time: Double) -> CIImage {
        var output = image
        if effects.preset != .none {
            let filtered = applyPreset(effects.preset, to: output)
            output = blend(original: output, filtered: filtered, amount: effects.presetIntensity)
        }
        if !effects.adjustments.isNeutral {
            output = applyAdjustments(effects.adjustments, to: output, time: time)
        }
        return output
    }

    static func applyPreset(_ preset: FilterPreset, to image: CIImage) -> CIImage {
        let extent = image.extent
        switch preset {
        case .none:
            return image
        case .vivid:
            return image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.08])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4])
        case .punch:
            return image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.18])
        case .warm:
            return temperature(image, warmth: 0.6, tint: 0.05)
        case .cool:
            return temperature(image, warmth: -0.6, tint: 0)
        case .cinematic:
            let graded = temperature(image, warmth: -0.15, tint: -0.1)
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputSaturationKey: 0.85])
            return vignette(graded, amount: 0.5)
        case .vintage:
            let sepia = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.9, kCIInputBrightnessKey: 0.03])
            return vignette(sepia, amount: 0.6)
        case .dreamy:
            return image
                .applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 12, kCIInputIntensityKey: 0.7])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
                .cropped(to: extent)
        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .instant:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .process:
            return image.applyingFilter("CIPhotoEffectProcess")
        case .transfer:
            return image.applyingFilter("CIPhotoEffectTransfer")
        case .tonal:
            return image.applyingFilter("CIPhotoEffectTonal")
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        }
    }

    static func applyAdjustments(_ adjustments: Adjustments, to image: CIImage, time: Double) -> CIImage {
        let extent = image.extent
        var output = image
        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustments.brightness,
                kCIInputContrastKey: adjustments.contrast,
                kCIInputSaturationKey: adjustments.saturation
            ])
        }
        if adjustments.warmth != 0 || adjustments.tint != 0 {
            output = temperature(output, warmth: adjustments.warmth, tint: adjustments.tint)
        }
        if adjustments.sharpen > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adjustments.sharpen * 2])
        }
        if adjustments.blur > 0 {
            output = output.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: adjustments.blur * 0.02 * max(extent.width, extent.height)])
                .cropped(to: extent)
        }
        if adjustments.vignette > 0 {
            output = vignette(output, amount: adjustments.vignette)
        }
        if adjustments.grain > 0 {
            output = grain(output, amount: adjustments.grain, time: time)
        }
        return output.cropped(to: extent)
    }

    static func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        // A neutral above the target warms the image; below cools it.
        image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500 + warmth * 2500, y: tint * 60),
            "inputTargetNeutral": CIVector(x: 6500, y: 0)
        ])
    }

    static func vignette(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        return image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: max(extent.width, extent.height) * 0.62,
            kCIInputIntensityKey: amount * 1.2,
            "inputFalloff": 0.6
        ]).cropped(to: extent)
    }

    static func grain(_ image: CIImage, amount: Double, time: Double) -> CIImage {
        let extent = image.extent
        let offset = CGFloat((time * 97).truncatingRemainder(dividingBy: 500))
        let noise = CIFilter.randomGenerator().outputImage?
            .transformed(by: CGAffineTransform(translationX: offset, y: offset * 0.7))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.22))
            ])
            .cropped(to: extent)
        guard let noise else { return image }
        return noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    static func blend(original: CIImage, filtered: CIImage, amount: Double) -> CIImage {
        guard amount < 0.999 else { return filtered }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: filtered,
            kCIInputTimeKey: amount.clamped(0...1)
        ]).cropped(to: original.extent)
    }

    static func opacity(_ image: CIImage, _ value: Double) -> CIImage {
        guard value < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(value.clamped(0...1)))
        ])
    }

    // MARK: Chroma key

    private static let cubeLock = NSLock()
    private static var cubeCache: [String: Data] = [:]
    private static let cubeSize = 32

    static func chromaKey(_ image: CIImage, settings: ChromaKey) -> CIImage {
        let data = cube(hue: settings.color.hue, tolerance: settings.tolerance, softness: settings.softness)
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
    }

    private static func cube(hue targetHue: Double, tolerance: Double, softness: Double) -> Data {
        let key = String(format: "%.3f|%.3f|%.3f", targetHue, tolerance, softness)
        cubeLock.lock()
        if let cached = cubeCache[key] {
            cubeLock.unlock()
            return cached
        }
        cubeLock.unlock()

        let size = cubeSize
        var values = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let red = Double(r) / Double(size - 1)
                    let green = Double(g) / Double(size - 1)
                    let blue = Double(b) / Double(size - 1)
                    let (h, s, v) = hsv(red, green, blue)
                    var alpha = 1.0
                    if s > 0.2 && v > 0.15 {
                        let raw = abs(h - targetHue)
                        let distance = min(raw, 1 - raw)
                        if distance < tolerance {
                            alpha = 0
                        } else if distance < tolerance + softness, softness > 0 {
                            alpha = (distance - tolerance) / softness
                        }
                    }
                    values[offset] = Float(red * alpha)
                    values[offset + 1] = Float(green * alpha)
                    values[offset + 2] = Float(blue * alpha)
                    values[offset + 3] = Float(alpha)
                    offset += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cubeLock.lock()
        if cubeCache.count > 20 { cubeCache.removeAll() }
        cubeCache[key] = data
        cubeLock.unlock()
        return data
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }

    // MARK: Transitions

    /// Blends two full-canvas frames. `progress` runs 0...1 across the transition.
    static func transition(_ kind: TransitionKind, from a: CIImage, to b: CIImage, progress: Double, canvas: CGRect) -> CIImage {
        let p = Easing.easeInOut.apply(progress)
        let black = CIImage(color: .black).cropped(to: canvas)
        switch kind {
        case .cut:
            return progress < 0.5 ? a : b
        case .fade:
            if p < 0.5 {
                return opacity(a, 1 - p * 2).composited(over: black)
            }
            return opacity(b, (p - 0.5) * 2).composited(over: black)
        case .dissolve:
            return a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: p])
                .cropped(to: canvas)
        case .slide:
            let width = canvas.width
            let outgoing = a.transformed(by: CGAffineTransform(translationX: -width * CGFloat(p), y: 0))
            let incoming = b.transformed(by: CGAffineTransform(translationX: width * CGFloat(1 - p), y: 0))
            return incoming.composited(over: outgoing).composited(over: black).cropped(to: canvas)
        case .zoom:
            let scale = 1 + CGFloat(p) * 0.6
            let zoomed = scaled(a, by: scale, around: canvas.center)
            let incoming = scaled(b, by: 1.25 - 0.25 * CGFloat(p), around: canvas.center)
            return opacity(incoming, p).composited(over: zoomed).cropped(to: canvas)
        case .spin:
            let angle = CGFloat(p) * .pi
            let outgoing = rotated(scaled(a, by: max(0.01, 1 - CGFloat(p)), around: canvas.center), by: angle, around: canvas.center)
            let incoming = rotated(scaled(b, by: max(0.01, CGFloat(p)), around: canvas.center), by: angle - .pi, around: canvas.center)
            let top = p < 0.5 ? outgoing : incoming
            let bottom = p < 0.5 ? incoming : outgoing
            return top.composited(over: bottom).composited(over: black).cropped(to: canvas)
        case .glitch:
            let base = p < 0.5 ? a : b
            let strength = CGFloat(sin(progress * .pi))
            let shift = strength * canvas.width * 0.03
            let red = base.applyingFilter("CIColorMatrix", parameters: [
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ]).transformed(by: CGAffineTransform(translationX: shift, y: 0))
            let green = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
            let blue = base.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ]).transformed(by: CGAffineTransform(translationX: -shift, y: shift * 0.3))
            var output = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
                .cropped(to: canvas)
            // Horizontal slice displacement.
            let slices = 6
            let sliceHeight = canvas.height / CGFloat(slices)
            for index in 0..<slices where (index + Int(progress * 10)) % 3 == 0 {
                let rect = CGRect(x: canvas.minX, y: canvas.minY + CGFloat(index) * sliceHeight, width: canvas.width, height: sliceHeight * 0.4)
                let jitter = strength * canvas.width * 0.06 * (index % 2 == 0 ? 1 : -1)
                let slice = output.cropped(to: rect).transformed(by: CGAffineTransform(translationX: jitter, y: 0))
                output = slice.composited(over: output)
            }
            return output.composited(over: black).cropped(to: canvas)
        }
    }

    static func scaled(_ image: CIImage, by scale: CGFloat, around center: CGPoint) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    static func rotated(_ image: CIImage, by angle: CGFloat, around center: CGPoint) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
