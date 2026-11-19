import AVFoundation
import Foundation

/// FlatGrid's interface sounds. Every sound is synthesised in memory at launch, so the app ships
/// no audio files and reads none.
@MainActor
final class Sounds {
    static let shared = Sounds()

    enum Effect: CaseIterable { case favoriteOn, favoriteOff, zoomIn, zoomOut }

    private var hoverPlayers: [AVAudioPlayer] = []
    private var nextHover = 0
    private var lastHover: TimeInterval = 0
    private var effects: [Effect: [AVAudioPlayer]] = [:]
    private var nextEffect: [Effect: Int] = [:]

    private init() {
        // Hover tick: a few pitches, two players each, so quick sweeps overlap cleanly.
        for frequency in [2100.0, 2350.0, 1900.0, 2600.0] {
            let data = Self.wav(duration: 0.014) { t in
                let attack = min(1, t * 44_100 / 12)
                let tone = sin(2 * .pi * frequency * t) + 0.35 * sin(2 * .pi * frequency * 2.01 * t)
                return tone * attack * exp(-t * 420) * 0.7
            }
            for _ in 0..<2 { if let player = Self.player(data, volume: 0.22) { hoverPlayers.append(player) } }
        }
        hoverPlayers.shuffle()

        // Favorite: two soft bell notes a fifth apart, the second landing just after the first.
        let like = Self.wav(duration: 0.42) { t in
            Self.bell(t, start: 0, frequency: 784) + Self.bell(t, start: 0.085, frequency: 1175) * 0.9
        }
        // Unfavorite: one lower note that falls away.
        let unlike = Self.wav(duration: 0.22) { t in
            let frequency = 520 - 150 * min(1, t / 0.2)
            return sin(2 * .pi * frequency * t) * min(1, t / 0.004) * exp(-t * 16) * 0.5
        }
        effects[.favoriteOn] = [Self.player(like, volume: 0.5), Self.player(like, volume: 0.5)].compactMap { $0 }
        effects[.favoriteOff] = [Self.player(unlike, volume: 0.4), Self.player(unlike, volume: 0.4)].compactMap { $0 }
        effects[.zoomIn] = [Self.player(Self.sweep(from: 320, to: 980), volume: 0.3), Self.player(Self.sweep(from: 320, to: 980), volume: 0.3)].compactMap { $0 }
        effects[.zoomOut] = [Self.player(Self.sweep(from: 980, to: 320), volume: 0.3), Self.player(Self.sweep(from: 980, to: 320), volume: 0.3)].compactMap { $0 }
    }

    /// The tick as the cursor crosses onto another thumbnail.
    func hover() {
        guard !hoverPlayers.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHover > 0.028 else { return }   // fast sweeps would otherwise buzz
        lastHover = now
        let player = hoverPlayers[nextHover]
        nextHover = (nextHover + 1) % hoverPlayers.count
        player.currentTime = 0
        player.play()
    }

    func play(_ effect: Effect) {
        guard let pool = effects[effect], !pool.isEmpty else { return }
        let index = nextEffect[effect, default: 0]
        nextEffect[effect] = (index + 1) % pool.count
        pool[index].currentTime = 0
        pool[index].play()
    }

    // MARK: Synthesis

    /// A struck-bell note: quick attack, long soft decay, a little shimmer on top.
    private static func bell(_ t: Double, start: Double, frequency: Double) -> Double {
        let local = t - start
        guard local >= 0 else { return 0 }
        let envelope = min(1, local / 0.003) * exp(-local * 11)
        let tone = sin(2 * .pi * frequency * local)
            + 0.28 * sin(2 * .pi * frequency * 2 * local) * exp(-local * 18)
            + 0.12 * sin(2 * .pi * frequency * 3.01 * local) * exp(-local * 30)
        return tone * envelope * 0.42
    }

    /// A short airy glide between two pitches.
    private static func sweep(from: Double, to: Double) -> Data {
        let duration = 0.17
        var phase = 0.0
        var noise = SplitMix64(seed: 77)
        var filtered = 0.0
        return wav(duration: duration) { t in
            let progress = t / duration
            let eased = progress * progress * (3 - 2 * progress)
            let frequency = from * pow(to / from, eased)
            phase += 2 * .pi * frequency / 44_100
            let white = Double(noise.next() % 2000) / 1000 - 1
            filtered += (white - filtered) * 0.25
            let envelope = sin(.pi * progress)
            return (sin(phase) * 0.5 + filtered * 0.12) * envelope * envelope
        }
    }

    private static func player(_ data: Data, volume: Float) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: data) else { return nil }
        player.volume = volume
        player.prepareToPlay()
        return player
    }

    /// 16-bit mono 44.1 kHz WAV built from a sample function of time in seconds.
    private static func wav(duration: Double, _ sample: (Double) -> Double) -> Data {
        let count = Int(44_100 * duration)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let value = sample(Double(index) / 44_100)
            samples[index] = Int16(max(-1, min(1, value)) * 32_000)
        }
        // Fade the last few milliseconds so nothing ends on a click.
        let tail = min(count, 220)
        for offset in 0..<tail {
            let index = count - tail + offset
            samples[index] = Int16(Double(samples[index]) * Double(tail - offset) / Double(tail))
        }
        let dataSize = UInt32(count * 2)
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(44_100).littleEndian); append(UInt32(88_200).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(dataSize.littleEndian)
        samples.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: count)) }
        return data
    }
}
