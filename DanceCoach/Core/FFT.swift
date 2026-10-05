import Foundation
import Accelerate

/// 固定大小、可复用的实数 FFT。
/// 数组全部预分配，因为节拍检测要跑上万次，每次重新分配会很慢。
final class FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let mags: UnsafeMutablePointer<Float>
    /// 幅度谱长度（实信号的一半）
    let binCount: Int

    init?(size: Int) {
        guard size >= 8, size & (size - 1) == 0 else { return nil }
        self.size = size
        self.binCount = size / 2
        self.log2n = vDSP_Length(round(log2(Double(size))))
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
        window = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        realp = .allocate(capacity: size / 2)
        imagp = .allocate(capacity: size / 2)
        mags = .allocate(capacity: size / 2)
        window.initialize(repeating: 0, count: size)
        windowed.initialize(repeating: 0, count: size)
        realp.initialize(repeating: 0, count: size / 2)
        imagp.initialize(repeating: 0, count: size / 2)
        mags.initialize(repeating: 0, count: size / 2)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
        mags.deallocate()
    }

    /// 输入 size 个样本，返回幅度谱指针（有效长度 binCount，用完即失效）
    func magnitudes(_ input: ArraySlice<Float>) -> UnsafeMutablePointer<Float> {
        var tmp = [Float](repeating: 0, count: size)
        for (k, v) in input.enumerated() where k < size { tmp[k] = v }
        return magnitudes(tmp)
    }

    func magnitudes(_ input: [Float]) -> UnsafeMutablePointer<Float> {
        let n = vDSP_Length(size)
        input.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, window, 1, windowed, 1, n)
        }
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(size / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, mags, 1, vDSP_Length(size / 2))
        return mags
    }
}
