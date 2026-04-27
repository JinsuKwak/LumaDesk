import CoreMedia
import Foundation

final class DynamicLightingEngine {
    var diagnosticsHandler: ((CaptureDiagnostics) -> Void)?
    var outputHandler: (@MainActor (RGBColor) -> Void)?

    private let captureService: ScreenCaptureService
    private let analyzer: ColorAnalysisService
    private let queue = DispatchQueue(label: "LumaDesk.DynamicLightingEngine", qos: .userInitiated)
    private let frameCoalescingLock = NSLock()

    private var isRunning = false
    private var configuration = DynamicEngineConfiguration(
        analysisMode: .full,
        colorExtractionMethod: .weightedAverage,
        brightnessCap: 0.7,
        updateRate: 12,
        smoothing: 0.3,
        centerSamplingRect: .defaultCenter,
        edgeSamplingWidthPercent: 12,
        edgeZoneCount: 12,
        saturationWeight: 1.35,
        saturationBoost: 0.15,
        gamma: 2.2,
        blackThreshold: 0.03,
        mutedDarkOffEnabled: true,
        mutedDarkLuminanceThreshold: 0.12,
        mutedDarkSaturationThreshold: 0.12,
        pureWhiteSnapEnabled: true,
        pureWhiteLuminanceThreshold: 0.82,
        pureWhiteSaturationThreshold: 0.10,
        calibratedWhiteColor: RGBColor(red: 1, green: 1, blue: 1)
    )
    private var lastDiagnostics = CaptureDiagnostics()
    private var latestFrame: CapturedFrame?
    private var lastSentSourceTime: CMTime = .invalid
    private var lastOutputColor: RGBColor?
    private var lastEmitDate: Date?
    private var activeCaptureFrameRate: Int?
    private var lastDiagnosticsPublishDate: Date?
    private var frameWorkScheduled = false
    private var pendingFrame: CapturedFrame?

    init(captureService: ScreenCaptureService, analyzer: ColorAnalysisService) {
        self.captureService = captureService
        self.analyzer = analyzer

        captureService.shouldAcceptFrame = { [weak self] in
            self?.shouldAcceptFrame() ?? false
        }

        captureService.frameHandler = { [weak self] frame in
            self?.handle(frame: frame)
        }

        captureService.streamStateHandler = { [weak self] state, error in
            self?.queue.async {
                guard let self else { return }
                self.lastDiagnostics.streamState = state
                self.lastDiagnostics.lastError = error
                if state == .error {
                    self.isRunning = false
                    self.latestFrame = nil
                    self.clearQueuedFrames()
                    self.lastSentSourceTime = .invalid
                    self.lastOutputColor = nil
                    self.lastEmitDate = nil
                    self.activeCaptureFrameRate = nil
                }
                self.publishDiagnostics(force: true)
            }
        }
    }

    func start(configuration: DynamicEngineConfiguration) {
        queue.async {
            self.configuration = configuration
            let needsFreshStart = !self.isRunning
            self.isRunning = true
            self.activeCaptureFrameRate = configuration.updateRate
            self.latestFrame = nil
            self.clearQueuedFrames()
            self.lastSentSourceTime = .invalid
            self.lastOutputColor = nil
            self.lastEmitDate = nil
            self.lastDiagnosticsPublishDate = nil
            self.lastDiagnostics = CaptureDiagnostics(streamState: self.lastDiagnostics.streamState)
            self.publishDiagnostics(force: true)

            guard needsFreshStart else {
                self.captureService.scheduleFrameRateUpdate(configuration.updateRate)
                return
            }

            Task {
                await self.captureService.start(frameRate: configuration.updateRate)
            }
        }
    }

    func update(configuration: DynamicEngineConfiguration) {
        queue.async {
            let previousConfiguration = self.configuration
            self.configuration = configuration
            guard self.isRunning else { return }

            if self.needsImmediateReanalysis(from: previousConfiguration, to: configuration) {
                self.lastSentSourceTime = .invalid
                self.lastOutputColor = nil
                self.lastEmitDate = nil

                if let latestFrame = self.latestFrame {
                    self.process(frame: latestFrame, forceEmit: true)
                }
            }

            if configuration.updateRate != previousConfiguration.updateRate || self.activeCaptureFrameRate != configuration.updateRate {
                self.activeCaptureFrameRate = configuration.updateRate
                self.captureService.scheduleFrameRateUpdate(configuration.updateRate)
            }
        }
    }

    func stop() {
        queue.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.latestFrame = nil
            self.lastSentSourceTime = .invalid
            self.lastOutputColor = nil
            self.lastEmitDate = nil
            self.activeCaptureFrameRate = nil
            self.lastDiagnostics.streamState = .idle
            self.clearQueuedFrames()
            self.publishDiagnostics(force: true)
            self.captureService.stop()
        }
    }

    private func handle(frame: CapturedFrame) {
        frameCoalescingLock.lock()
        if frameWorkScheduled {
            pendingFrame = frame
            frameCoalescingLock.unlock()
            return
        }

        frameWorkScheduled = true
        frameCoalescingLock.unlock()

        queue.async {
            self.drainFrames(startingWith: frame)
        }
    }

    private func shouldAcceptFrame() -> Bool {
        frameCoalescingLock.lock()
        let shouldAccept = !frameWorkScheduled || pendingFrame == nil
        frameCoalescingLock.unlock()
        return shouldAccept
    }

    private func drainFrames(startingWith firstFrame: CapturedFrame) {
        var frame: CapturedFrame? = firstFrame

        while let currentFrame = frame {
            if isRunning {
                latestFrame = currentFrame
                process(frame: currentFrame, forceEmit: false)
            }

            frameCoalescingLock.lock()
            if let queuedFrame = pendingFrame {
                pendingFrame = nil
                frame = queuedFrame
            } else {
                frameWorkScheduled = false
                frame = nil
            }
            frameCoalescingLock.unlock()
        }
    }

    private func clearQueuedFrames() {
        frameCoalescingLock.lock()
        pendingFrame = nil
        frameCoalescingLock.unlock()
    }

    private func process(frame: CapturedFrame, forceEmit: Bool) {
        let analysis = analyzer.analyze(
            frame: frame,
            mode: configuration.analysisMode,
            centerSamplingRect: configuration.centerSamplingRect,
            edgeSamplingWidthPercent: configuration.edgeSamplingWidthPercent,
            edgeZoneCount: configuration.edgeZoneCount,
            extractionMethod: configuration.colorExtractionMethod,
            saturationWeight: configuration.saturationWeight
        )

        lastDiagnostics.frameCount += 1
        lastDiagnostics.analysisCount += 1
        lastDiagnostics.lastFrameTime = frame.receivedAt
        lastDiagnostics.lastAnalyzedTime = analysis.capturedAt
        lastDiagnostics.lastFrameStatus = forceEmit ? "\(frame.statusLabel) reanalyzed" : frame.statusLabel
        lastDiagnostics.frameSize = "\(analysis.frameWidth)x\(analysis.frameHeight)"
        lastDiagnostics.pixelFormat = analysis.pixelFormat
        lastDiagnostics.screenColor = analysis.color
        lastDiagnostics.sampleCount = analysis.sampleCount
        let didEmit = emit(analysis: analysis, force: forceEmit)
        publishDiagnostics(force: forceEmit || didEmit)
    }

    @discardableResult
    private func emit(analysis latestAnalysis: FrameAnalysis, force: Bool = false) -> Bool {
        guard isRunning else { return false }
        guard latestAnalysis.sourceTime != lastSentSourceTime else { return false }

        let now = Date()
        let maximumOutputRate = min(max(configuration.updateRate, 1), 8)
        let minimumOutputInterval = 1.0 / Double(maximumOutputRate)
        if !force, let lastEmitDate, now.timeIntervalSince(lastEmitDate) < minimumOutputInterval {
            return false
        }

        var nextColor = latestAnalysis.color
        var usesCalibratedWhite = false

        if configuration.blackThreshold > 0,
           latestAnalysis.luminance < configuration.blackThreshold
        {
            nextColor = .black
        } else if configuration.mutedDarkOffEnabled,
                  latestAnalysis.luminance < configuration.mutedDarkLuminanceThreshold,
                  latestAnalysis.saturation < configuration.mutedDarkSaturationThreshold
        {
            nextColor = .black
        } else if configuration.pureWhiteSnapEnabled,
                  latestAnalysis.luminance >= configuration.pureWhiteLuminanceThreshold,
                  latestAnalysis.saturation <= configuration.pureWhiteSaturationThreshold
        {
            nextColor = configuration.calibratedWhiteColor.scaled(toBrightness: configuration.brightnessCap)
            usesCalibratedWhite = true
        }

        if nextColor.brightness > 0.001 {
            if !usesCalibratedWhite {
                nextColor = nextColor.saturationBoosted(by: configuration.saturationBoost)
                nextColor = nextColor.scaled(toBrightness: configuration.brightnessCap)
                nextColor = nextColor.gammaCorrected(configuration.gamma)
            }
        }

        if let previousColor = lastOutputColor {
            let blendAmount = max(0.1, 1.0 - configuration.smoothing)
            nextColor = previousColor.blended(toward: nextColor, amount: blendAmount)
        }

        if !force, let previousColor = lastOutputColor, colorDistance(previousColor, nextColor) < 0.015 {
            lastSentSourceTime = latestAnalysis.sourceTime
            return false
        }

        lastSentSourceTime = latestAnalysis.sourceTime
        lastOutputColor = nextColor
        lastEmitDate = now
        lastDiagnostics.sendCount += 1
        lastDiagnostics.lastSentTime = Date()
        lastDiagnostics.ledColor = nextColor

        let outputColor = nextColor
        Task {
            await MainActor.run {
                outputHandler?(outputColor)
            }
        }
        return true
    }

    private func publishDiagnostics(force: Bool = false) {
        let now = Date()
        if !force,
           let lastDiagnosticsPublishDate,
           now.timeIntervalSince(lastDiagnosticsPublishDate) < 0.25
        {
            return
        }

        lastDiagnosticsPublishDate = now
        diagnosticsHandler?(lastDiagnostics)
    }

    private func colorDistance(_ lhs: RGBColor, _ rhs: RGBColor) -> Double {
        abs(lhs.red - rhs.red) + abs(lhs.green - rhs.green) + abs(lhs.blue - rhs.blue)
    }

    private func needsImmediateReanalysis(
        from previous: DynamicEngineConfiguration,
        to next: DynamicEngineConfiguration
    ) -> Bool {
        previous.analysisMode != next.analysisMode
            || previous.colorExtractionMethod != next.colorExtractionMethod
            || previous.centerSamplingRect != next.centerSamplingRect
            || previous.edgeSamplingWidthPercent != next.edgeSamplingWidthPercent
            || previous.edgeZoneCount != next.edgeZoneCount
            || previous.saturationWeight != next.saturationWeight
            || previous.saturationBoost != next.saturationBoost
            || previous.gamma != next.gamma
            || previous.blackThreshold != next.blackThreshold
            || previous.mutedDarkOffEnabled != next.mutedDarkOffEnabled
            || previous.mutedDarkLuminanceThreshold != next.mutedDarkLuminanceThreshold
            || previous.mutedDarkSaturationThreshold != next.mutedDarkSaturationThreshold
            || previous.pureWhiteSnapEnabled != next.pureWhiteSnapEnabled
            || previous.pureWhiteLuminanceThreshold != next.pureWhiteLuminanceThreshold
            || previous.pureWhiteSaturationThreshold != next.pureWhiteSaturationThreshold
            || previous.calibratedWhiteColor != next.calibratedWhiteColor
            || previous.brightnessCap != next.brightnessCap
            || previous.smoothing != next.smoothing
    }
}

private extension RGBColor {
    func saturationBoosted(by amount: Double) -> RGBColor {
        let hsb = hueSaturationBrightness
        guard hsb.brightness > 0.02, hsb.saturation > 0.04 else { return self }

        let boostedSaturation = (hsb.saturation * (1.0 + amount.clamped(to: 0 ... 1))).clamped(to: 0 ... 1)
        return RGBColor(hue: hsb.hue, saturation: boostedSaturation, brightness: hsb.brightness)
    }

    func gammaCorrected(_ gamma: Double) -> RGBColor {
        let gamma = gamma.clamped(to: 1 ... 4)
        return RGBColor(
            red: pow(red, gamma),
            green: pow(green, gamma),
            blue: pow(blue, gamma)
        )
    }

}
