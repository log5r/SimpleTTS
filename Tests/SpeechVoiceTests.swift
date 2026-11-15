import Foundation

@main
struct SpeechVoiceTests {
    static func main() throws {
        let japanese: [String: Any] = [
            "boundLanguage": "ja",
            "voiceId": "com.apple.ttsbundle.gryphon-neural_TestJapanese_ja-JP_premium",
        ]
        let english: [String: Any] = [
            "boundLanguage": "en",
            "voiceId": "com.apple.ttsbundle.gryphon-neural_TestEnglish_en-US_compact",
        ]
        let selections: [Any] = ["en", english, "ja", japanese]
        try require(SayCommand.configuredVoiceName(in: selections, preferredLanguages: ["ja-JP", "en-US"])
                    == String(localized: "\("TestJapanese") Premium"), "Default voice ignored the preferred language")
        try require(SayCommand.configuredVoiceName(in: selections, preferredLanguages: ["en-GB", "ja"])
                    == "TestEnglish", "Default voice ignored language priority")
        try require(SayCommand.configuredVoiceName(in: selections, preferredLanguages: ["fr-FR"]) == nil,
                    "An unrelated language was presented as the default")
        try require(SayCommand.configuredVoiceName(in: ["ja", ["boundLanguage": "ja", "voiceId": "unknown-format"]],
                                                  preferredLanguages: ["ja-JP"]) == nil,
                    "An unknown identifier was guessed")
        try require(SayCommand.configuredVoiceName(in: [], preferredLanguages: ["ja"]) == nil,
                    "Missing preferences produced a voice")
        let regional: [String: Any] = [
            "boundLanguage": "en-US",
            "voiceId": "com.apple.ttsbundle.gryphon-neural_TestRegional_en-US_enhanced",
        ]
        try require(SayCommand.configuredVoiceName(in: [english, regional], preferredLanguages: ["en-US"])
                    == String(localized: "\("TestRegional") Enhanced"), "Exact locale did not take precedence")
        let voices = SayCommand.parseVoiceList("""
        Test Voice en_US # Hello
        Kyoko ja_JP # こんにちは
        Test Voice en_US # Hello again
        """)
        try require(voices.map(\.name) == ["Kyoko", "Test Voice"], "Voice names or duplicate handling changed")
        print("PASS: default voice language selection, neural voice names, quality, unknown settings, and say voice list")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SpeechVoiceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
