import Testing
@testable import CohereTranscribe

@Suite("Text language check")
struct TextLanguageCheckTests {
    @Test("German speech written as English is redone in German")
    func mixedGermanEnglish() {
        // A real dictation that Silero took for English.
        let text = """
        Also, Braindump funktioniert ganz gut, aber ich finde es blöd, dass man, wenn man einen \
        Braindump generiert, dass dann bei letzte Diktate Nur the Braindump is to find and I can see \
        my diktat, my eigentlich diktat, not seeing it. Also, I think it would be better if this \
        diktat here is and when Pavarotti is opened, it would be able to open the Löschen and \
        Kopieren button.
        """
        #expect(TextLanguageCheck.correctedLanguage(for: text, transcribedAs: "en") == "de")
    }

    @Test("Real English stays English")
    func plainEnglish() {
        let text = "I think we should ship the new build on Monday and then ask the team for feedback."
        #expect(TextLanguageCheck.correctedLanguage(for: text, transcribedAs: "en") == nil)
    }

    @Test("German with English terms stays German")
    func germanWithEnglishTerms() {
        let text = "Ich habe das Meeting mit dem Team verschoben, weil der Pull Request noch nicht durch die CI ist."
        #expect(TextLanguageCheck.correctedLanguage(for: text, transcribedAs: "de") == nil)
    }

    @Test("English speech written as German is redone in English")
    func englishWrittenAsGerman() {
        let text = "And then I said that we would like to have the meeting on Friday because it is easier for you."
        #expect(TextLanguageCheck.correctedLanguage(for: text, transcribedAs: "de") == "en")
    }

    @Test("Short texts are left alone")
    func shortText() {
        #expect(TextLanguageCheck.correctedLanguage(for: "Ja, danke.", transcribedAs: "en") == nil)
    }

    @Test("Other languages are not checked")
    func otherLanguage() {
        #expect(TextLanguageCheck.correctedLanguage(for: "Ich bin heute nicht da und du auch nicht", transcribedAs: "fr") == nil)
    }
}
