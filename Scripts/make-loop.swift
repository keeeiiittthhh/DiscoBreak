import Foundation

// Synthesises the bundled DiscoBreak loop from scratch: 8 bars of 120 BPM
// four-on-the-floor. Written here rather than sourced, so the shipped build
// carries no third-party rights. Output: 16-bit stereo WAV at 44.1k.

let sr = 44100.0
let bpm = 120.0
let beat = 60.0 / bpm            // 0.5s
let bars = 8
let total = beat * 4 * Double(bars)
let n = Int(total * sr)

var left = [Double](repeating: 0, count: n)
var right = [Double](repeating: 0, count: n)

var rngState: UInt64 = 0xD15C0
func noise() -> Double {
    rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: rngState >> 11)) / Double(1 << 52) - 1.0
}

func add(_ at: Double, _ dur: Double, _ pan: Double = 0, _ gen: (Double) -> Double) {
    let start = Int(at * sr)
    let count = Int(dur * sr)
    for i in 0..<count {
        let idx = start + i
        guard idx >= 0, idx < n else { continue }
        let v = gen(Double(i) / sr)
        left[idx]  += v * (1 - max(0, pan))
        right[idx] += v * (1 + min(0, pan))
    }
}

// --- voices ----------------------------------------------------------------

func kick(_ t: Double) {
    add(t, 0.42) { s in
        let f = 45 + 95 * exp(-s / 0.028)          // pitch drop: click into body
        let env = exp(-s / 0.11)
        let click = exp(-s / 0.004) * 0.35
        return (sin(2 * .pi * f * s) * env + click) * 0.95
    }
}

func hat(_ t: Double, open: Bool, gain: Double) {
    let dur = open ? 0.20 : 0.05
    var prev = 0.0
    add(t, dur, 0.15) { s in
        let raw = noise()
        let hp = raw - prev * 0.72                  // crude high-pass: cymbals are all top
        prev = raw
        return hp * exp(-s / (open ? 0.075 : 0.012)) * gain
    }
}

func clap(_ t: Double) {
    // Three fast bursts then a tail — that stagger is what makes a clap a clap.
    for (i, off) in [0.0, 0.011, 0.023].enumerated() {
        var prev = 0.0
        add(t + off, 0.06, -0.2) { s in
            let raw = noise()
            let bp = raw - prev * 0.5
            prev = raw
            return bp * exp(-s / 0.008) * (i == 2 ? 0.5 : 0.35)
        }
    }
    var prev = 0.0
    add(t + 0.023, 0.22, -0.2) { s in
        let raw = noise(); let bp = raw - prev * 0.55; prev = raw
        return bp * exp(-s / 0.055) * 0.30
    }
}

func bass(_ t: Double, _ freq: Double, _ dur: Double) {
    var lp = 0.0
    add(t, dur) { s in
        let phase = (freq * s).truncatingRemainder(dividingBy: 1)
        let saw = 2 * phase - 1
        let env = min(1, s / 0.006) * exp(-s / (dur * 0.55))
        lp += ((saw * env) - lp) * 0.16              // one-pole lowpass: round, not buzzy
        return lp * 0.75
    }
}

func stab(_ t: Double, _ freqs: [Double]) {
    for f in freqs {
        for detune in [0.997, 1.003] {
            add(t, 0.30, 0.0) { s in
                let phase = (f * detune * s).truncatingRemainder(dividingBy: 1)
                let saw = 2 * phase - 1
                let env = min(1, s / 0.004) * exp(-s / 0.075)
                return saw * env * 0.10
            }
        }
    }
}

// --- arrangement -----------------------------------------------------------

let A1 = 55.0, F1 = 43.65
let Am7: [Double] = [220.00, 261.63, 329.63, 392.00]     // A C E G
let Fmaj7: [Double] = [174.61, 220.00, 261.63, 329.63]   // F A C E

for bar in 0..<bars {
    let b0 = Double(bar) * beat * 4
    let firstHalf = bar < 4
    let root = firstHalf ? A1 : F1
    let chord = firstHalf ? Am7 : Fmaj7

    for b in 0..<4 {
        let t = b0 + Double(b) * beat
        kick(t)
        hat(t + beat * 0.5, open: true, gain: 0.30)      // offbeat open hat: the disco tell
        hat(t + beat * 0.25, open: false, gain: 0.16)
        hat(t + beat * 0.75, open: false, gain: 0.16)
        if b == 1 || b == 3 { clap(t) }

        // Octave-jumping bass on eighths.
        bass(t, root, beat * 0.45)
        bass(t + beat * 0.5, root * 2, beat * 0.45)
    }

    // Chord stabs on the and-of-2 and and-of-4, plus a lift into each 4-bar half.
    stab(b0 + beat * 1.5, chord)
    stab(b0 + beat * 3.5, chord)
    if bar % 4 == 3 { stab(b0 + beat * 3.75, chord.map { $0 * 1.5 }) }
}

// --- master ----------------------------------------------------------------

var peak = 0.0
for i in 0..<n { peak = max(peak, max(abs(left[i]), abs(right[i]))) }
let norm = peak > 0 ? 0.92 / peak : 1

var pcm = Data(capacity: n * 4)
for i in 0..<n {
    // Soft clip, then a 12ms fade at each end so the loop point is silent.
    let edge = min(1.0, Double(i) / (sr * 0.012), Double(n - 1 - i) / (sr * 0.012))
    for ch in [left, right] {
        let v = tanh(ch[i] * norm * 1.1) * 0.95 * edge
        var s = Int16(max(-32767, min(32767, v * 32767)))
        withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
var wav = Data()
wav.append("RIFF".data(using: .ascii)!)
wav.append(le(UInt32(36 + pcm.count)))
wav.append("WAVEfmt ".data(using: .ascii)!)
wav.append(le(UInt32(16)))
wav.append(le(UInt16(1)))                  // PCM
wav.append(le(UInt16(2)))                  // stereo
wav.append(le(UInt32(44100)))
wav.append(le(UInt32(44100 * 4)))          // byte rate
wav.append(le(UInt16(4)))                  // block align
wav.append(le(UInt16(16)))                 // bits
wav.append("data".data(using: .ascii)!)
wav.append(le(UInt32(pcm.count)))
wav.append(pcm)

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./loop.wav"
try wav.write(to: URL(fileURLWithPath: out))
print(String(format: "wrote %@ — %.1fs, peak %.2f", out, total, peak))
