import CohereTranscribe
import DesignSystem
import Dictation
import SwiftUI

// Pavarotti: the language for dictation and meetings, from all the languages the chosen
// model knows.

extension DictationSettingsSection {
    var languageRows: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingXS) {
            Picker("Language", selection: languageBinding) {
                Text("Automatic (German or English)").tag(TranscriptionLanguage.automatic)
                Divider()
                ForEach(Self.languages(of: chosenModel), id: \.self) { language in
                    Text(Self.name(of: language)).tag(language)
                }
            }
            if chosenModel.backend.detectsLanguage {
                statusText("This model recognizes the spoken language by itself.")
            }
        }
    }

    private var chosenModel: CohereModel {
        CohereModel.model(id: controller.settings.modelID) ?? .recommended
    }

    /// The model's languages, sorted by their names.
    static func languages(of model: CohereModel) -> [TranscriptionLanguage] {
        model.languages
            .compactMap(TranscriptionLanguage.init(rawValue:))
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    /// The language's name in the app's language, such as "German" or "Deutsch".
    static func name(of language: TranscriptionLanguage) -> String {
        guard let code = language.code else { return language.rawValue }
        let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return appLocale.localizedString(forLanguageCode: code) ?? code
    }

    private var languageBinding: Binding<TranscriptionLanguage> {
        Binding(
            get: { controller.settings.language },
            set: { newValue in controller.update { $0.language = newValue } }
        )
    }
}
