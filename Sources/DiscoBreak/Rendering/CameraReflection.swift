import AVFoundation
import CoreVideo
import Metal

/// The Mac's camera, as something for the third ball's mirrors to reflect.
///
/// Opt-in and off by default. It runs only while the ball is down — started on
/// the drop, stopped on the retract — so the green camera light is an honest
/// signal. Frames go from the camera straight into a Metal texture through
/// `CVMetalTextureCache`: no copies, nothing written anywhere, and nothing kept
/// but the latest frame.
final class CameraReflection: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    /// macOS asks once. After a no it answers no without asking; the user has to
    /// change it in System Settings.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    private let device: MTLDevice
    private let session = AVCaptureSession()
    /// Setup, start, stop and every frame happen here, never on the main thread.
    private let queue = DispatchQueue(label: "DiscoBreak.camera")
    private var cache: CVMetalTextureCache?
    private var configured = false

    private let lock = NSLock()
    private var newest: CVMetalTexture?

    /// Nil unless the user has said yes and there is a camera to use; the ball
    /// then reflects its studio lights instead.
    init?(device: MTLDevice) {
        guard Self.isAuthorized, Self.isAvailable else { return nil }
        self.device = device
        super.init()
    }

    func start() {
        queue.async {
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            self.session.stopRunning()
            self.keep(nil)
            if let cache = self.cache { CVMetalTextureCacheFlush(cache, 0) }
        }
    }

    /// The newest frame, plus the object that must stay alive while the GPU reads it.
    func latest() -> (texture: MTLTexture, owner: CVMetalTexture)? {
        lock.lock()
        let frame = newest
        lock.unlock()
        guard let frame, let texture = CVMetalTextureGetTexture(frame) else { return nil }
        return (texture, frame)
    }

    private func configure() {
        configured = true
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else { return }

        session.beginConfiguration()
        // Each tile shows a few pixels of this. VGA is plenty, and cheap.
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let cache, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixels, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &texture)
        keep(texture)
    }

    private func keep(_ frame: CVMetalTexture?) {
        lock.lock()
        newest = frame
        lock.unlock()
    }
}
