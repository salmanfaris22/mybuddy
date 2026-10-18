import MyBuddyCore
import MyBuddyDesign
import SwiftUI

/// Shared notes: a list and an editor. What you type here appears on your phone, and the other way round.
struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: Note?

    var body: some View {
        let notes = model.notes
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MBSpace.s) {
                HStack {
                    Text("\(notes.visible.count) note\(notes.visible.count == 1 ? "" : "s")").font(MBFont.headline).foregroundStyle(MBColor.textPrimary)
                    Spacer()
                    Button { notes.newNote() } label: { Label("New note", systemImage: "square.and.pencil") }
                        .buttonStyle(MBButtonStyle(.primary, compact: true))
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New note (⌘N)")
                }
                Text(notes.syncStatus).font(MBFont.callout).foregroundStyle(MBColor.textTertiary).lineLimit(2)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(notes.visible) { note in
                            NoteRow(note: note, selected: notes.selectedId == note.id) { notes.selectedId = note.id }
                                .contextMenu { Button("Delete", role: .destructive) { confirmDelete = note } }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(MBSpace.l)
            .frame(width: 280)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(MBColor.surface)

            Divider().overlay(MBColor.border)

            Group {
                if let note = notes.selected {
                    NoteEditor(note: note, onDelete: { confirmDelete = note })
                } else {
                    StateView(.empty, title: notes.visible.isEmpty ? "No notes yet" : "No note selected",
                              message: "Notes you write here appear on your phone, and notes from your phone appear here. They stay on your two devices — never on a server.") {
                        Button("New note") { notes.newNote() }.buttonStyle(MBButtonStyle(.primary))
                    }
                    .frame(maxWidth: 460)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = confirmDelete?.id { notes.delete(id) }
                confirmDelete = nil
            }
        } message: { Text("It’s removed from this Mac and from your phone.") }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary).lineLimit(1)
                HStack(spacing: MBSpace.xs) {
                    Text(Date(timeIntervalSince1970: Double(note.updatedAt) / 1000).formatted(.relative(presentation: .named)))
                    if !note.preview.isEmpty { Text("· \(note.preview)").lineLimit(1) }
                }
                .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MBSpace.m)
            .padding(.vertical, MBSpace.s)
            .background(RoundedRectangle(cornerRadius: MBRadius.md, style: .continuous)
                .fill(selected ? MBColor.elevatedHover : (hovering ? MBColor.elevated : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(note.title). \(note.preview)")
    }
}

private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    let note: Note
    let onDelete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MBSpace.s) {
            HStack {
                Text("Edited \(Date(timeIntervalSince1970: Double(note.updatedAt) / 1000).formatted(date: .abbreviated, time: .shortened))")
                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                Spacer()
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    .buttonStyle(MBButtonStyle(.ghost, compact: true))
            }
            TextEditor(text: Binding(get: { model.notes.book.notes[note.id]?.text ?? "" }, set: { model.notes.update(note.id, text: $0) }))
                .font(.system(size: 14))
                .foregroundStyle(MBColor.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .accessibilityLabel("Note text")
        }
        .padding(MBSpace.xl)
        .onAppear { if note.text.isEmpty { focused = true } }
        .id(note.id)
    }
}
