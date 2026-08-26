import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScreenCaptureService: NSObject {
    var shouldAcceptFrame: (() -> Bool)?
    var frameHandler: ((CapturedFrame) -> Void)?
    var streamStateHandler: ((CaptureStreamState, String?) -> Void)?

    private let sampleQueue = DispatchQueue(label: "LumaDesk.ScreenCapture.Output", qos: .userInitiated)
    private var stream: SCStream?
    private var currentDisplay: SCDisplay?
    private var configuredFrameRate = 20
    private var frameRateUpdateTask: Task<Void, Never>?
    private var watchdogTimer: DispatchSourceTimer?
    private var lastStreamFrameDate: Date?
    private var lastFallbackFrameDate: Date?
    private var fallbackBackoffUntil: Date?
    private var fallbackCaptureInFlight = false
    private var intentionalStopInFlight = false
    private var copyBufferPool: CVPixelBufferPool?
    private var copyBufferPoolKey: PixelBufferPoolKey?

    func start(frameRate: Int) async {
        configuredFrameRate = frameRate

        if stream != nil {
            scheduleFrameRateUpdate(frameRate)
            return
        }

        streamStateHandler?(.starting, nil)

        do {
            let display = try await resolvePrimaryDisplay()
            let configuration = makeConfiguration(for: display, frameRate: frameRate)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

            self.stream = stream
            self.currentDisplay = display
            self.lastStreamFrameDate = nil
            self.lastFallbackFrameDate = nil
            self.fallbackBackoffUntil = nil
            self.fallbackCaptureInFlight = false
            self.intentionalStopInFlight = false
            try await stream.startCapture()
            startWatchdog()
            streamStateHandler?(.active, nil)
        } catch {
            clearCaptureState()
            stopWatchdog()
            streamStateHandler?(.error, error.localizedDescription)
        }
    }

    func stop() {
        frameRateUpdateTask?.cancel()
        frameRateUpdateTask = nil
        stopWatchdog()

        guard let stream else {
            streamStateHandler?(.idle, nil)
            return
        }

        intentionalStopInFlight = true

        Task {
            do {
                try? stream.removeStreamOutput(self, type: .screen)
                try await stream.stopCapture()
            } catch {
                // A user/system stop can race the delegate callback; the stale stream is discarded below.
            }

            self.intentionalStopInFlight = false
            self.clearCaptureState()
            self.streamStateHandler?(.idle, nil)
        }
    }

    func scheduleFrameRateUpdate(_ frameRate: Int) {
        configuredFrameRate = frameRate
        frameRateUpdateTask?.cancel()
        frameRateUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.applyFrameRateUpdate()
        }
    }

    private func applyFrameRateUpdate() async {
        guard let stream, let currentDisplay else { return }

        do {
            try await stream.updateConfiguration(makeConfiguration(for: currentDisplay, frameRate: configuredFrameRate))
        } catch {
            invalidateActiveCapture(message: error.localizedDescription)
        }
    }

    private func resolvePrimaryDisplay() async throws -> SCDisplay {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let primaryDisplayID = CGMainDisplayID()

        if let display = shareableContent.displays.first(where: { CGDirectDisplayID($0.displayID) == primaryDisplayID }) {
            return display
        }

        throw NSError(
            domain: "LumaDesk.ScreenCapture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Primary display not found"]
        )
    }

    private func makeConfiguration(for display: SCDisplay, frameRate: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = captureSize(for: display)

        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        return configuration
    }

    private func captureSize(for display: SCDisplay) -> (width: Int, height: Int) {
        let longEdge = max(display.width, display.height)
        let scale = min(1.0, 160.0 / Double(longEdge))
        return (
            width: Int((Double(display.width) * scale).rounded()),
            height: Int((Double(display.height) * scale).rounded())
        )
    }

    private func startWatchdog() {
        watchdogTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + .milliseconds(750), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.emitFallbackFrameIfStreamIsStale()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func emitFallbackFrameIfStreamIsStale() {
        guard stream != nil, let currentDisplay else { return }
        guard !fallbackCaptureInFlight else { return }
        guard CGPreflightScreenCaptureAccess() else {
            invalidateActiveCapture(message: "Screen Recording permission unavailable")
            return
        }

        let now = Date()
        if let fallbackBackoffUntil, now < fallbackBackoffUntil {
            return
        }

        let streamAge = lastStreamFrameDate.map { now.timeIntervalSince($0) } ?? .infinity
        let staleThreshold = max(0.75, 2.0 / Double(max(configuredFrameRate, 1)))
        guard streamAge > staleThreshold else { return }

        let fallbackRate = min(max(configuredFrameRate, 1), 8)
        let minimumFallbackInterval = 1.0 / Double(fallbackRate)
        if let lastFallbackFrameDate,
           now.timeIntervalSince(lastFallbackFrameDate) < minimumFallbackInterval
        {
            return
        }

        fallbackCaptureInFlight = true
        let configuration = makeConfiguration(for: currentDisplay, frameRate: configuredFrameRate)
        let filter = SCContentFilter(display: currentDisplay, excludingWindows: [])

        Task { [weak self] in
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )

                let pixelBuffer = autoreleasepool {
                    self?.makePixelBuffer(from: image, width: configuration.width, height: configuration.height)
                }

                guard let pixelBuffer else {
                    self?.finishFallbackCapture(error: nil)
                    return
                }

                self?.finishFallbackCapture(pixelBuffer: pixelBuffer)
            } catch {
                self?.finishFallbackCapture(error: error)
            }
        }
    }

    private func finishFallbackCapture(pixelBuffer: CVPixelBuffer? = nil, error: Error? = nil) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.fallbackCaptureInFlight = false

            if let error {
                self.invalidateActiveCapture(message: "Capture stopped: \(error.localizedDescription)")
                return
            }

            guard self.stream != nil, let pixelBuffer else { return }

            let now = Date()
            self.lastFallbackFrameDate = now
            self.fallbackBackoffUntil = nil
            self.streamStateHandler?(.active, nil)
            self.frameHandler?(
                CapturedFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTimeStamp: CMTime(
                        value: Int64(now.timeIntervalSinceReferenceDate * 1_000_000_000),
                        timescale: 1_000_000_000
                    ),
                    receivedAt: now,
                    statusLabel: "fallback"
                )
            )
        }
    }

    private func makePixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixelBuffer
    }

    private func invalidateActiveCapture(message: String, stopUnderlyingStream: Bool = true) {
        let streamToStop = stream
        frameRateUpdateTask?.cancel()
        frameRateUpdateTask = nil
        stopWatchdog()
        clearCaptureState()
        streamStateHandler?(.error, message)

        if stopUnderlyingStream, let streamToStop {
            Task {
                try? streamToStop.removeStreamOutput(self, type: .screen)
                try? await streamToStop.stopCapture()
            }
        }
    }

    private func clearCaptureState() {
        stream = nil
        currentDisplay = nil
        lastStreamFrameDate = nil
        lastFallbackFrameDate = nil
        fallbackBackoffUntil = nil
        fallbackCaptureInFlight = false
        flushCopyBufferPool()
    }
}

extension ScreenCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { [weak self] in
            guard let self else { return }

            let wasIntentionalStop = self.intentionalStopInFlight
            self.intentionalStopInFlight = false

            if wasIntentionalStop {
                self.frameRateUpdateTask?.cancel()
                self.frameRateUpdateTask = nil
                self.stopWatchdog()
                self.clearCaptureState()
                self.streamStateHandler?(.idle, nil)
            } else {
                self.invalidateActiveCapture(
                    message: "Capture stopped: \(error.localizedDescription)",
                    stopUnderlyingStream: false
                )
            }
        }
    }
}

extension ScreenCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        autoreleasepool {
            processSampleBuffer(sampleBuffer, outputType: outputType)
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let status = attachments?.first?[.status] as? Int
        let frameStatus = status.flatMap(SCFrameStatus.init(rawValue:))

        if let frameStatus, frameStatus == .suspended || frameStatus == .stopped {
            return
        }

        lastStreamFrameDate = Date()
        guard shouldAcceptFrame?() ?? true else { return }

        guard let copiedPixelBuffer = copyPixelBuffer(pixelBuffer) else { return }

        let label = frameStatusLabel(frameStatus)
        let frame = CapturedFrame(
            pixelBuffer: copiedPixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            receivedAt: Date(),
            statusLabel: label
        )
        frameHandler?(frame)
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard let destination = pooledPixelBuffer(width: width, height: height, pixelFormat: pixelFormat) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(source),
              let destinationBaseAddress = CVPixelBufferGetBaseAddress(destination)
        else {
            return nil
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let bytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)

        for row in 0 ..< height {
            memcpy(
                destinationBaseAddress.advanced(by: row * destinationBytesPerRow),
                sourceBaseAddress.advanced(by: row * sourceBytesPerRow),
                bytesPerRow
            )
        }

        return destination
    }

    private func pooledPixelBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        let key = PixelBufferPoolKey(width: width, height: height, pixelFormat: pixelFormat)

        if copyBufferPool == nil || copyBufferPoolKey != key {
            copyBufferPool = makeCopyBufferPool(width: width, height: height, pixelFormat: pixelFormat)
            copyBufferPoolKey = key
        }

        guard let copyBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let auxiliaryAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 4,
        ] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            copyBufferPool,
            auxiliaryAttributes,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess else { return nil }

        return pixelBuffer
    }

    private func makeCopyBufferPool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ]

        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        guard result == kCVReturnSuccess else { return nil }
        return pool
    }

    private func flushCopyBufferPool() {
        if let copyBufferPool {
            CVPixelBufferPoolFlush(copyBufferPool, .excessBuffers)
        }

        copyBufferPool = nil
        copyBufferPoolKey = nil
    }

    private func frameStatusLabel(_ status: SCFrameStatus?) -> String {
        guard let status else { return "unknown" }

        switch status {
        case .complete:
            return "complete"
        case .idle:
            return "idle"
        case .blank:
            return "blank"
        case .suspended:
            return "suspended"
        case .started:
            return "started"
        case .stopped:
            return "stopped"
        @unknown default:
            return "raw \(status.rawValue)"
        }
    }
}

private struct PixelBufferPoolKey: Equatable {
    var width: Int
    var height: Int
    var pixelFormat: OSType
}
