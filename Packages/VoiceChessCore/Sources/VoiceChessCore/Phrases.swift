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

/// How much the app announces without being asked.
public enum HelpLevel: String, CaseIterable, Sendable {
    /// Own move, the bot's reply, check and "Your move".
    case full
    /// Only the bot's reply.
    case moves
    /// A tone when it is the player's turn; the player asks what happened.
    case nothing
}

/// Spoken commands the app handles locally without calling /say.
public enum VoiceCommand: Equatable, Sendable {
    case readBoard
    case readMyPieces
    case repeatLast
    case newGame
    /// Stop talking. Matches only the whole utterance, so questions such as "how do I stop the attack"
    /// still reach the server.
    case stop
    case helpLevel(HelpLevel)
    /// Show the board for a few seconds when it is hidden.
    case showBoard
    case hideBoard
    /// Start the post-game review.
    case review

    private static let stopPhrases: Set<String> = ["stop", "stop talking", "be quiet", "cancel"]
    private static let reviewPhrases: Set<String> = ["review", "start review", "review game"]

    public static func parse(_ text: String) -> VoiceCommand? {
        let words = normalizeSpeech(text)
        let plain = words.filter { $0 != "please" }.joined(separator: " ")
        if stopPhrases.contains(plain) { return .stop }
        if reviewPhrases.contains(plain) { return .review }
        let phrase = " " + words.joined(separator: " ") + " "
        func has(_ needle: String) -> Bool { phrase.contains(" \(needle) ") }
        if has("help level full") || has("full help") { return .helpLevel(.full) }
        if has("help level moves") || has("help level move") || has("moves only") { return .helpLevel(.moves) }
        if has("help level nothing") || has("help level none") || has("no help") { return .helpLevel(.nothing) }
        if has("hide the board") || has("hide board") { return .hideBoard }
        if has("show the board") || has("show board") || has("reveal") { return .showBoard }
        if has("review my game") || has("review the game") || has("review my mistakes")
            || has("go through my mistakes") || has("go over my mistakes") { return .review }
        if has("read my pieces") || has("read my piece") { return .readMyPieces }
        if has("read the board") || has("read board") { return .readBoard }
        if has("new game") { return .newGame }
        if has("repeat") || has("say that again") { return .repeatLast }
        return nil
    }
}

/// What the player can say between reviewed moves. Whole-utterance matches only.
public enum ReviewCommand: Equatable, Sendable {
    case next
    case repeatExplanation
    case leave

    private static let nextPhrases: Set<String> = [
        "next", "next one", "next move", "yes", "yeah", "yep", "yup", "sure", "ok", "okay",
        "continue", "go on", "carry on", "go ahead",
    ]
    private static let repeatPhrases: Set<String> = ["repeat", "repeat that", "again", "say that again", "once more"]
    private static let leavePhrases: Set<String> = [
        "stop", "done", "no", "nope", "nah", "quit", "exit", "leave", "finish", "enough", "cancel",
        "stop review", "end review", "stop reviewing", "im done", "i am done",
    ]

    /// Speech-recognition contextual strings for the "Next?" prompt.
    public static let phrases = ["next", "yes", "continue", "repeat", "stop", "done", "no"]

    public static func parse(_ text: String) -> ReviewCommand? {
        let phrase = normalizeSpeech(text).filter { $0 != "please" }.joined(separator: " ")
        if nextPhrases.contains(phrase) { return .next }
        if repeatPhrases.contains(phrase) { return .repeatExplanation }
        if leavePhrases.contains(phrase) { return .leave }
        return nil
    }
}

/// Whether a transcript is a question for the coach, using the same openers the server treats as
/// questions (docs/api.md `question` outcome). Used where /say must not be called.
public enum QuestionDetector {
    private static let openers: Set<String> = [
        "what", "whats", "why", "how", "hows", "where", "wheres", "which", "who", "when",
        "should", "can", "could", "would", "is", "are", "does", "do", "did",
        "tell", "explain", "analyse", "analyze",
    ]

    public static func isQuestion(_ text: String) -> Bool {
        guard let first = normalizeSpeech(text).first else { return false }
        return openers.contains(first)
    }
}
