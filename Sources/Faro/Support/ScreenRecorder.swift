import AppKit
import AVFoundation
import ScreenCaptureKit

/// Lo que el guion necesita de la grabación, la haga quien la haga.
@MainActor
protocol DemoCapture: AnyObject {
    /// Segundos desde el inicio de la grabación.
    var elapsed: Double { get }
    /// Qué se ha grabado y dónde está cada cosa, para el montaje.
    var info: [String: Any] { get }
    func stop() async -> String
}

/// Graba la pantalla con ScreenCaptureKit, pero solo las ventanas de Faro (la terminal y la isla
/// del notch) sobre fondo transparente: es lo que pinta macOS de verdad, a 60 fps reales y con
/// todas las animaciones. Necesita el permiso de grabación de pantalla; si no lo hay, el guion
/// usa DemoRecorder.
final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "faro.demo.capture")
    private let startTime: CFTimeInterval
    private var lastTime = -1.0
    private var frames = 0
    private var skipped = 0
    let geometry: [String: Any]

    @MainActor
    static func make(window: NSWindow, url: URL) async throws -> ScreenRecorder {
        // La primera vez macOS pregunta; si no hay permiso, se graba de la otra forma.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw CocoaError(.featureUnsupported) }
        guard let screen = window.screen ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CocoaError(.featureUnsupported) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let app = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier })
        else { throw CocoaError(.featureUnsupported) }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.backgroundColor = .clear
        config.showsCursor = false
        config.queueDepth = 8
        config.ignoreShadowsDisplay = true
        // Solo las ventanas de esta app (también las que se abran después, como la isla).
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        let frame = window.frame
        let geometry: [String: Any] = [
            "mode": "screen",
            "width": config.width, "height": config.height, "scale": scale,
            // En puntos, con el origen arriba a la izquierda de la pantalla.
            "windowX": frame.minX - screen.frame.minX, "windowY": screen.frame.maxY - frame.maxY,
            "notchWidth": Island.notch(of: screen)?.width ?? 185, "notchHeight": Island.notch(of: screen)?.height ?? 32,
        ]
        let recorder = try ScreenRecorder(filter: filter, config: config, url: url, geometry: geometry)
        try await recorder.stream.startCapture()
        return recorder
    }

    private init(filter: SCContentFilter, config: SCStreamConfiguration, url: URL, geometry: [String: Any]) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 90_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        startTime = CACurrentMediaTime()
        self.geometry = geometry
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let buffer = sample.imageBuffer else { return }
        // Solo los fotogramas con algo nuevo (cuando no cambia nada, ScreenCaptureKit no manda imagen).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        // El reloj de ScreenCaptureKit es el mismo que el del guion (CACurrentMediaTime).
        let t = sample.presentationTimeStamp.seconds - startTime
        guard t >= 0, t > lastTime else { return }
        guard input.isReadyForMoreMediaData else { skipped += 1; return }
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 60_000)) {
            frames += 1
            lastTime = t
        }
    }

    var elapsed: Double { CACurrentMediaTime() - startTime }

    func stop() async -> String {
        try? await stream.stopCapture()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.input.markAsFinished()
                self.writer.finishWriting { done.resume() }
            }
        }
        return "pantalla: fotogramas=\(frames) perdidos=\(skipped) estado=\(writer.status.rawValue) \(writer.error.map { "\($0)" } ?? "")"
    }
}

@MainActor
final class ScreenCapture: DemoCapture {
    let recorder: ScreenRecorder
    init(_ recorder: ScreenRecorder) { self.recorder = recorder }
    var elapsed: Double { recorder.elapsed }
    var info: [String: Any] { recorder.geometry }
    func stop() async -> String { await recorder.stop() }
}
