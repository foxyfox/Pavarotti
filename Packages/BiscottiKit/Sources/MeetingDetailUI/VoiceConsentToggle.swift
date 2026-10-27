import DataStore
import DesignSystem
import Intelligence
import SwiftUI

/// Pavarotti: notes a person's consent to remember their voice, so it names them in
/// later meetings. Without the note their voice stays unknown there.
struct VoiceConsentToggle: View {
    let person: PersonData
    let store: VoiceConsentStore
    @State private var consentDate: Date?

    init(person: PersonData, store: VoiceConsentStore) {
        self.person = person
        self.store = store
        _consentDate = State(initialValue: store.consentDate(for: person.id))
    }

    var body: some View {
        Toggle("Remember voice", isOn: consentBinding)
            .toggleStyle(.checkbox)
            .font(Tokens.metadataFont)
            .help(helpText)
    }

    private var consentBinding: Binding<Bool> {
        Binding(
            get: { consentDate != nil },
            set: { given in
                store.setConsent(given, for: person.id)
                consentDate = store.consentDate(for: person.id)
            }
        )
    }

    private var helpText: String {
        if let consentDate {
            let noted = consentDate.formatted(date: .abbreviated, time: .omitted)
            return "\(person.name) agreed to have their voice remembered (noted \(noted)). It names them in later meetings."
        }
        return "Tick only if \(person.name) agreed to have their voice remembered. Until then it does not name them in later meetings."
    }
}
