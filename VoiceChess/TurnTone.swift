import Foundation

/// The short two-note chime played at help level Nothing when it is the player's turn.
/// Generated as 16-bit mono PCM WAV so it plays through the same audio path as the server voice.
enum TurnTone {
    static let wav: Data = {
        let sampleRate = 24_000
        // Rising pair: E5 then A5.
        let notes: [(frequency: Double, seconds: Double)] = [(659.25, 0.12), (880.0, 0.2)]
        var samples: [Int16] = []
        for note in notes {
            let count = Int(Double(sampleRate) * note.seconds)
            let fade = Int(Double(sampleRate) * 0.01)
            for index in 0..<count {
                let edge = min(index, count - 1 - index)
                let envelope = edge < fade ? Double(edge) / Double(fade) : 1.0
                let value = sin(2 * Double.pi * note.frequency * Double(index) / Double(sampleRate))
                samples.append(Int16(value * envelope * 0.5 * Double(Int16.max)))
            }
        }

        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        append("RIFF")
        append32(UInt32(36 + payload))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)  // PCM
        append16(1)  // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)  // block align
        append16(16)  // bits per sample
        append("data")
        append32(UInt32(payload))
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }()
}
