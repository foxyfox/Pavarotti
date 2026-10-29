import DataStore
import DesignSystem
import SwiftUI

/// Pavarotti: a speaker in the meeting header, next to the tags. Its menu says who the
/// speaker is, so naming a speaker needs no trip to the transcript.
struct SpeakerChip: View {
    let speaker: HeaderSpeaker
    let choices: SpeakerChoices
    let onAssign: (UUID) -> Void
    let onUnassign: () -> Void
    /// Opens the speaker sheet, which can also add a new person.
    let onMore: () -> Void

    @State private var hovered = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        // .menuStyle(.button) + .buttonStyle(.plain) shows the label as it is
        // (see the overflow menu in MeetingDetailView).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Who is speaking here?"))
    }

    // MARK: - Label

    private var label: some View {
        HStack(spacing: 5) {
            if let person = speaker.person {
                Avatar(
                    person: AvatarPerson(displayName: person.name, email: person.email),
                    size: 16
                )
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.inkTertiary)
                    .frame(width: 16, height: 16)
            }

            Text(speaker.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(speaker.person == nil ? .inkSecondary : .ink)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.inkTertiary)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(
            hovered ? Color.ink.opacity(0.1) : Color.neutralChip,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuContent: some View {
        if !choices.inMeeting.isEmpty {
            Section("In this meeting") {
                ForEach(choices.inMeeting) { choice($0) }
            }
        }
        if !choices.invited.isEmpty {
            Section("Invited") {
                ForEach(choices.invited) { choice($0) }
            }
        }
        if !choices.others.isEmpty {
            Menu("Everyone") {
                ForEach(choices.others) { choice($0) }
            }
        }

        Divider()

        Button("Other Person\u{2026}") { onMore() }

        if speaker.person != nil {
            Button("Remove Name") { onUnassign() }
        }
    }

    /// A person to pick, checked when the speaker is already them.
    private func choice(_ person: PersonData) -> some View {
        Toggle(
            person.name,
            isOn: Binding(
                get: { speaker.person?.id == person.id },
                set: { isOn in
                    if isOn { onAssign(person.id) }
                }
            )
        )
    }
}
