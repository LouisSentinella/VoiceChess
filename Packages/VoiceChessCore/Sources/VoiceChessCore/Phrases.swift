import Foundation

/// Lowercases, drops apostrophes and turns every other non-alphanumeric run into a single space.
func normalizeSpeech(_ text: String) -> [String] {
    var words: [String] = []
    var current = ""
    for scalar in text.lowercased().unicodeScalars {
        if scalar == "'" || scalar == "\u{2019}" { continue }
        if CharacterSet.alphanumerics.contains(scalar) {
            current.unicodeScalars.append(scalar)
        } else if !current.isEmpty {
            words.append(current)
            current = ""
        }
    }
    if !current.isEmpty { words.append(current) }
    return words
}

public enum YesNo: Equatable, Sendable {
    case yes, no

    private static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "correct", "confirm", "sure"]
    private static let noWords: Set<String> = ["no", "nope", "nah", "cancel", "wrong", "negative", "not", "dont"]

    /// The first decisive word wins ("that's not correct" is no); unknown input is nil.
    public static func parse(_ text: String) -> YesNo? {
        let words = normalizeSpeech(text)
        for (index, word) in words.enumerated() {
            if noWords.contains(word) { return .no }
            if yesWords.contains(word) { return .yes }
            if word == "play", index + 1 < words.count, words[index + 1] == "it" { return .yes }
        }
        return nil
    }
}

/// Spoken commands the app handles locally without calling /say.
public enum VoiceCommand: Equatable, Sendable {
    case readBoard
    case readMyPieces
    case repeatLast
    case newGame

    public static func parse(_ text: String) -> VoiceCommand? {
        let phrase = " " + normalizeSpeech(text).joined(separator: " ") + " "
        func has(_ needle: String) -> Bool { phrase.contains(" \(needle) ") }
        if has("read my pieces") || has("read my piece") { return .readMyPieces }
        if has("read the board") || has("read board") { return .readBoard }
        if has("new game") { return .newGame }
        if has("repeat") || has("say that again") { return .repeatLast }
        return nil
    }
}
