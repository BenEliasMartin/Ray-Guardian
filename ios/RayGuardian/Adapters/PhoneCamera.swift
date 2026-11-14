import AVFoundation
import CoreImage
import UIKit

@MainActor final class PhoneCamera {
    var onFrame: ((UIImage) -> Void)?
    private var generation = UUID()
    private let capture = Capture()

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() async throws {
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        try await capture.start { [weak self] image in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.onFrame?(image)
            }
        }
        guard generation == token else { throw CancellationError() }
    }

    func stop() {
        generation = UUID()
        capture.stop()
    }

    /// The capture session and frame delegate run on the same serial queue.
    private final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let queue = DispatchQueue(label: "Ray Guardian iPhone camera", qos: .userInitiated)
        private let context = CIContext()
        private var session: AVCaptureSession?
        private var onFrame: (@Sendable (UIImage) -> Void)?
        private var lastFrameAt = -Double.infinity

        func start(deliver: @escaping @Sendable (UIImage) -> Void) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        self.onFrame = deliver
                        if let session = self.session, session.isRunning {
                            continuation.resume()
                            return
                        }
                        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                              let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                            throw DeviceError.message("The iPhone camera is unavailable or permission is off.")
                        }
                        let input = try AVCaptureDeviceInput(device: camera)
                        let output = AVCaptureVideoDataOutput()
                        output.alwaysDiscardsLateVideoFrames = true
                        output.setSampleBufferDelegate(self, queue: self.queue)

                        let session = AVCaptureSession()
                        session.automaticallyConfiguresApplicationAudioSession = false
                        session.sessionPreset = .vga640x480
                        guard session.canAddInput(input), session.canAddOutput(output) else {
                            throw DeviceError.message("Couldn’t configure the iPhone camera.")
                        }
                        session.addInput(input)
                        session.addOutput(output)
                        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                            connection.videoRotationAngle = 90
                        }
                        session.startRunning()
                        guard session.isRunning else { throw DeviceError.message("The iPhone camera didn’t start.") }
                        self.session = session
                        self.lastFrameAt = -.infinity
                        continuation.resume()
                    } catch {
                        self.onFrame = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        func stop() {
            queue.async {
                self.onFrame = nil
                self.session?.stopRunning()
                self.session = nil
            }
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastFrameAt >= 0.125, let onFrame, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let frame = context.createCGImage(image, from: image.extent) else { return }
            lastFrameAt = now
            onFrame(UIImage(cgImage: frame))
        }
    }
}
