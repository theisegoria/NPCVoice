// ITU-R BS.1770-4 integrated loudness and dialogue normalisation (mono).
import Foundation

public enum Loudness {
    /// Gated: BS.1770 over 400 ms blocks (75% overlap), -70 LUFS absolute and -10 LU
    /// relative gates. ShortClip: shorter than one block, so the K-weighted mean square of
    /// the whole clip is reported ungated. Silent: nothing passed the absolute gate.
    public enum Method: String, Sendable { case gated, shortClip, silent }

    public struct Measurement: Sendable, Equatable {
        public var method: Method = .silent
        public var integratedLUFS = -1e9
        public var samplePeakDBFS = -1e9
    }

    public struct Policy: Sendable {
        public var targetLUFS = -23.0          // EBU R128 dialogue target
        public var peakCeilingDBFS = -1.0
        public var maximumBoostDB = 24.0
        public var maximumCutDB = 48.0
        public init() {}
    }

    struct Biquad { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }

    /// K-weighting (high shelf + RLB high-pass) for any sample rate via the bilinear transform.
    static func kWeighting(_ fs: Double) -> (shelf: Biquad, highPass: Biquad) {
        var shelf = Biquad(), hp = Biquad()
        do {
            let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
            let K = tan(Double.pi * f0 / fs), vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + K / q + K * K
            shelf = Biquad(b0: (vh + vb * K / q + K * K) / a0, b1: 2 * (K * K - vh) / a0, b2: (vh - vb * K / q + K * K) / a0,
                           a1: 2 * (K * K - 1) / a0, a2: (1 - K / q + K * K) / a0)
        }
        do {
            let f0 = 38.13547087602444, q = 0.5003270373238773, K = tan(Double.pi * f0 / fs), a0 = 1 + K / q + K * K
            hp = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / q + K * K) / a0)
        }
        return (shelf, hp)
    }

    private static func lufs(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }

    public static func measure(_ pcm: [Float], sampleRate fs: Double) -> Measurement {
        precondition(fs >= 8000 && fs <= 384_000, "sample rate outside 8..384 kHz")
        let (shelf, hp) = kWeighting(fs)
        let hop = max(1, Int((fs * 0.1).rounded())), block = 4 * hop
        var m = Measurement()
        var s1 = (0.0, 0.0), s2 = (0.0, 0.0)
        var hops: [Double] = []
        hops.reserveCapacity(pcm.count / hop + 1)
        var sum = 0.0, whole = 0.0, count = 0, peak = 0.0
        for sample in pcm {
            let x = Double(sample)
            peak = max(peak, abs(x))
            var y = shelf.b0 * x + s1.0
            s1 = (shelf.b1 * x - shelf.a1 * y + s1.1, shelf.b2 * x - shelf.a2 * y)
            let x2 = y
            y = hp.b0 * x2 + s2.0
            s2 = (hp.b1 * x2 - hp.a1 * y + s2.1, hp.b2 * x2 - hp.a2 * y)
            sum += y * y; whole += y * y
            count += 1
            if count == hop { hops.append(sum); sum = 0; count = 0 }
        }
        m.samplePeakDBFS = peak > 0 ? 20 * log10(peak) : -1e9
        if pcm.count < block {
            guard !pcm.isEmpty else { return m }
            let z = whole / Double(pcm.count)
            if z > 0 && lufs(z) > -70 { m.method = .shortClip; m.integratedLUFS = lufs(z) }
            return m
        }
        let blocks = hops.count >= 4 ? hops.count - 3 : 0
        let z = (0..<blocks).map { (hops[$0] + hops[$0 + 1] + hops[$0 + 2] + hops[$0 + 3]) / Double(block) }
        let l = z.map { $0 > 0 ? lufs($0) : -1e9 }
        func gatedMean(_ threshold: Double) -> (Double, Int) {
            var s = 0.0, n = 0
            for j in 0..<blocks where l[j] > threshold { s += z[j]; n += 1 }
            return n > 0 ? (s / Double(n), n) : (0, 0)
        }
        let (ungated, absolute) = gatedMean(-70)
        guard absolute > 0 else { return m }
        let (gated, n) = gatedMean(lufs(ungated) - 10)
        guard n > 0, gated > 0 else { return m }
        m.method = .gated
        m.integratedLUFS = lufs(gated)
        return m
    }

    /// Gain (dB) that moves the measurement to the target within the peak ceiling and bounds.
    public static func normalizationGainDB(_ m: Measurement, _ p: Policy = .init()) -> Double {
        guard m.method != .silent else { return 0 }
        var gain = min(max(p.targetLUFS - m.integratedLUFS, -p.maximumCutDB), p.maximumBoostDB)
        if m.samplePeakDBFS > -1e8 { gain = min(gain, p.peakCeilingDBFS - m.samplePeakDBFS) }
        return max(gain, -p.maximumCutDB)
    }

    /// Normalises in place; returns the measurement before normalisation and the gain applied.
    @discardableResult
    public static func normalize(_ pcm: inout [Float], sampleRate: Double, policy: Policy = .init()) -> (Measurement, Double) {
        let m = measure(pcm, sampleRate: sampleRate)
        let gainDB = normalizationGainDB(m, policy)
        let g = Float(pow(10, gainDB / 20))
        if gainDB != 0 { for i in pcm.indices { pcm[i] *= g } }
        return (m, gainDB)
    }
}
