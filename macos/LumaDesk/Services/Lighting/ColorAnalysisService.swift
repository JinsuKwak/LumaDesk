import CoreMedia
import CoreVideo
import Foundation

final class ColorAnalysisService {
    func analyze(
        frame: CapturedFrame,
        mode: DynamicAnalysisMode,
        centerSamplingRect: NormalizedRect,
        edgeSamplingWidthPercent: Double,
        edgeZoneCount: Int,
        extractionMethod: ColorExtractionMethod,
        saturationWeight: Double
    ) -> FrameAnalysis {
        let pixelBuffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return emptyAnalysis(
                frame: frame,
                width: width,
                height: height,
                pixelFormat: pixelFormat
            )
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let channelOrder = PixelChannelOrder(pixelFormat: pixelFormat)
        let sampleStride = max(1, Int(sqrt(Double(max(width * height, 1)) / 3_000.0)))

        switch mode {
        case .full:
            return analyzeFullFrame(
                baseAddress: baseAddress,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                sampleStride: sampleStride,
                channelOrder: channelOrder,
                extractionMethod: extractionMethod,
                saturationWeight: saturationWeight,
                frame: frame,
                pixelFormat: pixelFormat
            )
        case .center:
            return analyzeCenterFrame(
                baseAddress: baseAddress,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                sampleStride: sampleStride,
                channelOrder: channelOrder,
                centerSamplingRect: centerSamplingRect,
                extractionMethod: extractionMethod,
                saturationWeight: saturationWeight,
                frame: frame,
                pixelFormat: pixelFormat
            )
        case .edge:
            return analyzeEdgeZones(
                baseAddress: baseAddress,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                sampleStride: sampleStride,
                channelOrder: channelOrder,
                edgeSamplingWidthPercent: edgeSamplingWidthPercent,
                edgeZoneCount: edgeZoneCount,
                extractionMethod: extractionMethod,
                saturationWeight: saturationWeight,
                frame: frame,
                pixelFormat: pixelFormat
            )
        }
    }

    private func analyzeFullFrame(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        sampleStride: Int,
        channelOrder: PixelChannelOrder,
        extractionMethod: ColorExtractionMethod,
        saturationWeight: Double,
        frame: CapturedFrame,
        pixelFormat: OSType
    ) -> FrameAnalysis {
        var accumulator = ColorAccumulator()

        for y in Swift.stride(from: 0, to: height, by: sampleStride) {
            let row = baseAddress.advanced(by: y * bytesPerRow)

            for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                addPixel(
                    at: x,
                    row: row,
                    channelOrder: channelOrder,
                    extractionMethod: extractionMethod,
                    saturationWeight: saturationWeight,
                    accumulator: &accumulator
                )
            }
        }

        return makeAnalysis(
            color: accumulator.resolvedColor(method: extractionMethod) ?? .black,
            sampleCount: accumulator.observedCount,
            frame: frame,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }

    private func analyzeCenterFrame(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        sampleStride: Int,
        channelOrder: PixelChannelOrder,
        centerSamplingRect: NormalizedRect,
        extractionMethod: ColorExtractionMethod,
        saturationWeight: Double,
        frame: CapturedFrame,
        pixelFormat: OSType
    ) -> FrameAnalysis {
        var accumulator = ColorAccumulator()
        let rect = centerSamplingRect.clamped(minimumSize: 0.02)
        let minX = max(0, min(width - 1, Int((rect.x * Double(width)).rounded(.down))))
        let minY = max(0, min(height - 1, Int((rect.y * Double(height)).rounded(.down))))
        let maxX = max(minX + 1, min(width, Int(((rect.x + rect.width) * Double(width)).rounded(.up))))
        let maxY = max(minY + 1, min(height, Int(((rect.y + rect.height) * Double(height)).rounded(.up))))

        for y in Swift.stride(from: minY, to: maxY, by: sampleStride) {
            let row = baseAddress.advanced(by: y * bytesPerRow)

            for x in Swift.stride(from: minX, to: maxX, by: sampleStride) {
                addPixel(
                    at: x,
                    row: row,
                    channelOrder: channelOrder,
                    extractionMethod: extractionMethod,
                    saturationWeight: saturationWeight,
                    accumulator: &accumulator
                )
            }
        }

        return makeAnalysis(
            color: accumulator.resolvedColor(method: extractionMethod) ?? .black,
            sampleCount: accumulator.observedCount,
            frame: frame,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }

    private func analyzeEdgeZones(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        sampleStride: Int,
        channelOrder: PixelChannelOrder,
        edgeSamplingWidthPercent: Double,
        edgeZoneCount: Int,
        extractionMethod: ColorExtractionMethod,
        saturationWeight: Double,
        frame: CapturedFrame,
        pixelFormat: OSType
    ) -> FrameAnalysis {
        let edgeWidth = max(1, Int((Double(min(width, height)) * edgeSamplingWidthPercent / 100).rounded()))
        let zoneCount = max(4, min(edgeZoneCount, 64))
        var accumulators = Array(repeating: ColorAccumulator(), count: zoneCount)

        for y in Swift.stride(from: 0, to: height, by: sampleStride) {
            let row = baseAddress.advanced(by: y * bytesPerRow)

            for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                guard isEdgePixel(x: x, y: y, width: width, height: height, edgeWidth: edgeWidth) else {
                    continue
                }

                let zoneIndex = edgeZoneIndex(x: x, y: y, width: width, height: height, zoneCount: zoneCount)
                addPixel(
                    at: x,
                    row: row,
                    channelOrder: channelOrder,
                    extractionMethod: extractionMethod,
                    saturationWeight: saturationWeight,
                    accumulator: &accumulators[zoneIndex]
                )
            }
        }

        let sampleCount = accumulators.reduce(0) { $0 + $1.observedCount }
        let color = aggregateZoneColors(accumulators, method: extractionMethod)

        return makeAnalysis(
            color: color,
            sampleCount: sampleCount,
            frame: frame,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }

    private func addPixel(
        at x: Int,
        row: UnsafeMutableRawPointer,
        channelOrder: PixelChannelOrder,
        extractionMethod: ColorExtractionMethod,
        saturationWeight: Double,
        accumulator: inout ColorAccumulator
    ) {
        let offset = x * 4
        let pixel = row.advanced(by: offset).assumingMemoryBound(to: UInt8.self)

        accumulator.add(
            red: Double(pixel[channelOrder.red]) / 255.0,
            green: Double(pixel[channelOrder.green]) / 255.0,
            blue: Double(pixel[channelOrder.blue]) / 255.0,
            method: extractionMethod,
            saturationWeight: saturationWeight
        )
    }

    private func aggregateZoneColors(_ accumulators: [ColorAccumulator], method: ColorExtractionMethod) -> RGBColor {
        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var weightTotal = 0.0

        for accumulator in accumulators {
            guard let color = accumulator.resolvedColor(method: method) else { continue }

            // Sqrt keeps one bright zone influential without letting it completely erase the perimeter context.
            let weight = max(sqrt(accumulator.effectiveWeight), 0.05)
            redTotal += color.red * weight
            greenTotal += color.green * weight
            blueTotal += color.blue * weight
            weightTotal += weight
        }

        guard weightTotal > 0 else { return .black }

        return RGBColor(
            red: redTotal / weightTotal,
            green: greenTotal / weightTotal,
            blue: blueTotal / weightTotal
        )
    }

    private func isEdgePixel(x: Int, y: Int, width: Int, height: Int, edgeWidth: Int) -> Bool {
        x < edgeWidth
            || x >= width - edgeWidth
            || y < edgeWidth
            || y >= height - edgeWidth
    }

    private func edgeZoneIndex(x: Int, y: Int, width: Int, height: Int, zoneCount: Int) -> Int {
        let leftDistance = x
        let rightDistance = width - 1 - x
        let topDistance = y
        let bottomDistance = height - 1 - y
        let nearestDistance = min(leftDistance, rightDistance, topDistance, bottomDistance)

        let position: Double
        if topDistance == nearestDistance {
            position = Double(x)
        } else if rightDistance == nearestDistance {
            position = Double(width + y)
        } else if bottomDistance == nearestDistance {
            position = Double(width + height + (width - 1 - x))
        } else {
            position = Double(width + height + width + (height - 1 - y))
        }

        let perimeter = Double(max((width + height) * 2, 1))
        let normalizedPosition = position / perimeter
        return min(max(Int(normalizedPosition * Double(zoneCount)), 0), zoneCount - 1)
    }

    private func makeAnalysis(
        color: RGBColor,
        sampleCount: Int,
        frame: CapturedFrame,
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> FrameAnalysis {
        FrameAnalysis(
            color: color,
            luminance: color.luminance,
            saturation: color.saturation,
            sampleCount: sampleCount,
            frameWidth: width,
            frameHeight: height,
            pixelFormat: pixelFormatDescription(pixelFormat),
            sourceTime: frame.presentationTimeStamp,
            capturedAt: frame.receivedAt
        )
    }

    private func emptyAnalysis(frame: CapturedFrame, width: Int, height: Int, pixelFormat: OSType) -> FrameAnalysis {
        makeAnalysis(
            color: .black,
            sampleCount: 0,
            frame: frame,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
    }

    private func pixelFormatDescription(_ pixelFormat: OSType) -> String {
        let bytes = [
            UInt8((pixelFormat >> 24) & 0xff),
            UInt8((pixelFormat >> 16) & 0xff),
            UInt8((pixelFormat >> 8) & 0xff),
            UInt8(pixelFormat & 0xff),
        ]

        let printableBytes = bytes.filter { $0 >= 32 && $0 <= 126 }
        if printableBytes.count == 4,
           let text = String(bytes: printableBytes, encoding: .ascii)
        {
            return text
        }

        return String(pixelFormat)
    }
}

private struct ColorAccumulator {
    var observedCount = 0
    var effectiveWeight = 0.0
    private var redTotal = 0.0
    private var greenTotal = 0.0
    private var blueTotal = 0.0
    private var histogram: [Int: HistogramBucket] = [:]

    mutating func add(
        red: Double,
        green: Double,
        blue: Double,
        method: ColorExtractionMethod,
        saturationWeight: Double
    ) {
        observedCount += 1

        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        guard luminance > 0.015 else { return }

        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let saturation = maxComponent > 0 ? (maxComponent - minComponent) / maxComponent : 0
        let weight = pow(luminance, 0.85) * (1.0 + (saturation * saturationWeight.clamped(to: 0 ... 3)))

        guard weight > 0.0001 else { return }

        redTotal += red * weight
        greenTotal += green * weight
        blueTotal += blue * weight
        effectiveWeight += weight

        guard method == .dominant else { return }

        let key = quantizedKey(red: red, green: green, blue: blue)
        var bucket = histogram[key, default: HistogramBucket()]
        bucket.add(red: red, green: green, blue: blue, weight: weight)
        histogram[key] = bucket
    }

    func resolvedColor(method: ColorExtractionMethod) -> RGBColor? {
        switch method {
        case .weightedAverage:
            return weightedColor
        case .dominant:
            return histogram.values.max { $0.weight < $1.weight }?.color ?? weightedColor
        }
    }

    private var weightedColor: RGBColor? {
        guard effectiveWeight > 0 else { return nil }

        return RGBColor(
            red: redTotal / effectiveWeight,
            green: greenTotal / effectiveWeight,
            blue: blueTotal / effectiveWeight
        )
    }

    private func quantizedKey(red: Double, green: Double, blue: Double) -> Int {
        let redBucket = Int((red * 15).rounded()).clamped(to: 0 ... 15)
        let greenBucket = Int((green * 15).rounded()).clamped(to: 0 ... 15)
        let blueBucket = Int((blue * 15).rounded()).clamped(to: 0 ... 15)
        return (redBucket << 8) | (greenBucket << 4) | blueBucket
    }
}

private struct HistogramBucket {
    var weight = 0.0
    private var redTotal = 0.0
    private var greenTotal = 0.0
    private var blueTotal = 0.0

    mutating func add(red: Double, green: Double, blue: Double, weight: Double) {
        self.weight += weight
        redTotal += red * weight
        greenTotal += green * weight
        blueTotal += blue * weight
    }

    var color: RGBColor {
        guard weight > 0 else { return .black }

        return RGBColor(
            red: redTotal / weight,
            green: greenTotal / weight,
            blue: blueTotal / weight
        )
    }
}

private struct PixelChannelOrder {
    let red: Int
    let green: Int
    let blue: Int

    init(pixelFormat: OSType) {
        switch pixelFormat {
        case OSType(kCVPixelFormatType_32BGRA):
            red = 2
            green = 1
            blue = 0
        case OSType(kCVPixelFormatType_32ARGB):
            red = 1
            green = 2
            blue = 3
        case OSType(kCVPixelFormatType_32RGBA):
            red = 0
            green = 1
            blue = 2
        case OSType(kCVPixelFormatType_32ABGR):
            red = 3
            green = 2
            blue = 1
        default:
            red = 2
            green = 1
            blue = 0
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
