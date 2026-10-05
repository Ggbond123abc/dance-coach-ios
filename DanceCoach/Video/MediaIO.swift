import Foundation
import AVFoundation
import Vision
import CoreGraphics

enum MediaError: LocalizedError {
    case noVideoTrack
    case noAudioTrack
    case readerSetup
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频轨，可能不是视频文件。"
        case .noAudioTrack: return "这个视频没有音轨，节拍会改用骨架运动来推算。"
        case .readerSetup: return "打不开视频（格式可能不被支持）。"
        case .readerFailed(let s): return "读取视频失败：\(s)"
        }
    }
}

struct VideoInfo {
    var duration: Double
    var displaySize: CGSize
    var orientation: CGImagePropertyOrientation
    var frameRate: Float
}

struct PoseExtraction {
    var frames: [PoseFrame]
    var sampled: Int
    var detected: Int
}

enum MediaIO {

    // MARK: - 基本信息

    static func loadInfo(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw MediaError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let frameRate = try await track.load(.nominalFrameRate)

        let transformed = natural.applying(transform)
        let display = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        return VideoInfo(duration: duration,
                         displaySize: display,
                         orientation: orientation(from: transform),
                         frameRate: frameRate)
    }

    /// AVAssetReader 吐出来的像素是「未旋转」的，得把旋转信息告诉 Vision，
    /// 它转完之后返回的关键点就已经在对的坐标系里了。
    static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 { return .up }
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    // MARK: - 逐帧骨架提取

    /// 用 AVAssetReader 顺序解码，比边播边测快得多，而且是确定性的（不会漏帧）。
    static func extractPoses(url: URL, info: VideoInfo, progress: (Double) -> Void) throws -> PoseExtraction {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw MediaError.noVideoTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.readerSetup }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }

        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNSequenceRequestHandler()
        var frames: [PoseFrame] = []
        var sampled = 0
        var detected = 0
        let total = max(0.1, info.duration)

        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            sampled += 1

            do {
                try handler.perform([request], on: pixels, orientation: info.orientation)
            } catch {
                continue
            }
            guard let obs = request.results?.first else { continue }
            let lm = landmarks(from: obs)
            detected += 1
            frames.append(PoseFrame(t: t, lm: lm))

            if sampled % 20 == 0 { progress(min(1, t / total)) }
        }

        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }
        progress(1)
        return PoseExtraction(frames: frames, sampled: sampled, detected: detected)
    }

    /// Vision 的 19 个点映射到 MediaPipe 的 33 点编号。
    /// 拿不到的点（脚趾/脚跟/手指）可见度写 0，下游一律跳过。
    static func landmarks(from obs: VNHumanBodyPoseObservation) -> [Float] {
        var lm = emptyLandmarks()
        guard let pts = try? obs.recognizedPoints(.all) else { return lm }

        func put(_ joint: VNHumanBodyPoseObservation.JointName, _ dst: Int) {
            guard let p = pts[joint], p.confidence > 0.05 else { return }
            let o = dst * LM.stride
            lm[o] = Float(p.location.x)
            // Vision 的原点在左下角，我们统一用左上角
            lm[o + 1] = Float(1 - p.location.y)
            lm[o + 2] = 0
            lm[o + 3] = Float(p.confidence)
        }

        put(.nose, 0)
        put(.leftEye, 2)
        put(.rightEye, 5)
        put(.leftEar, 7)
        put(.rightEar, 8)
        put(.leftShoulder, LM.leftShoulder)
        put(.rightShoulder, LM.rightShoulder)
        put(.leftElbow, LM.leftElbow)
        put(.rightElbow, LM.rightElbow)
        put(.leftWrist, LM.leftWrist)
        put(.rightWrist, LM.rightWrist)
        put(.leftHip, LM.leftHip)
        put(.rightHip, LM.rightHip)
        put(.leftKnee, LM.leftKnee)
        put(.rightKnee, LM.rightKnee)
        put(.leftAnkle, LM.leftAnkle)
        put(.rightAnkle, LM.rightAnkle)
        return lm
    }

    // MARK: - 音频解码（给节拍检测用）

    /// 直接解成 22.05kHz 单声道 Float，交给 vDSP 做谱通量。
    static func monoPCM(url: URL, targetRate: Double = 22050) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw MediaError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: targetRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.readerSetup }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(targetRate * 150))
        while let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                     totalLengthOut: &length, dataPointerOut: &ptr)
            guard status == kCMBlockBufferNoErr, let p = ptr, length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            p.withMemoryRebound(to: Float.self, capacity: count) { fp in
                samples.append(contentsOf: UnsafeBufferPointer(start: fp, count: count))
            }
        }
        if reader.status == .failed {
            throw MediaError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }
        return samples
    }
}
