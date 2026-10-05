import Foundation
import AVFoundation
import Vision
import Combine
import CoreGraphics

/// 前置摄像头 + 实时骨架。
///
/// 参考视频那边用的是一个独立的 Vision 请求序列 —— 不能共用，
/// 两条流的时间轴不一样，混在一起会让跟踪状态错乱。
final class CameraTracker: NSObject, ObservableObject {

    @Published private(set) var latest: [Float]?
    @Published private(set) var bufferSize: CGSize = .zero
    @Published private(set) var isRunning = false
    @Published var errorText: String?

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "dancecoach.camera")
    private let output = AVCaptureVideoDataOutput()
    private let handler = VNSequenceRequestHandler()
    private let request = VNDetectHumanBodyPoseRequest()
    private var lastProcessed: CFTimeInterval = 0
    private var configured = false

    /// 限到 ~22fps：再快也只是白烧电，摄像头本身的延迟都比这大
    private let minInterval: CFTimeInterval = 1.0 / 22.0

    func start() {
        if configured {
            if !session.isRunning {
                queue.async { [weak self] in self?.session.startRunning() }
            }
            DispatchQueue.main.async { self.isRunning = true }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.errorText = "没拿到摄像头权限。去「设置 → 街舞拆解 → 相机」里打开，然后重进 App。"
                }
                return
            }
            self.configure()
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorText = "找不到可用的摄像头。" }
            return
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorText = "摄像头输出配置失败。" }
            return
        }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        session.commitConfiguration()
        configured = true

        queue.async { [weak self] in self?.session.startRunning() }
        DispatchQueue.main.async { self.isRunning = true }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        DispatchQueue.main.async {
            self.isRunning = false
            self.latest = nil
        }
    }

    func reset() {
        latest = nil
        lastProcessed = 0
    }
}

extension CameraTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= minInterval else { return }
        lastProcessed = now
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        do {
            try handler.perform([request], on: pixels, orientation: .up)
        } catch {
            return
        }
        guard let obs = request.results?.first else {
            DispatchQueue.main.async { self.latest = nil }
            return
        }
        let lm = MediaIO.landmarks(from: obs)
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        DispatchQueue.main.async {
            self.latest = lm
            self.bufferSize = size
        }
    }
}
