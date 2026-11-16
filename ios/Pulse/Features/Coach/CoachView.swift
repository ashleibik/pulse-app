import SwiftUI

/// The in-app coach (Phase 9): a chat about your own Pulse data.
///
/// The app never holds an AI key. It sends the conversation to the user's own server function,
/// which adds the last 14 days of summaries and asks Claude (supabase/functions/coach).
/// The conversation lives only in memory here: closing the sheet forgets it.
/// Mono design (ios/design/DESIGN.md): your messages are black pills, the coach answers in plain text.
struct CoachView: View {
    @Environment(CloudManager.self) private var cloud
    @Environment(\.dismiss) private var dismiss

    @State private var conversation: [CloudManager.ChatMessage] = []
    @State private var draft = ""
    @State private var waiting = false
    @FocusState private var typing: Bool

    private let suggestions = ["How did I sleep this week?", "Should I train hard today?", "Why is my recovery low?"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if !cloud.isSignedIn {
                        EmptyState(symbol: "bubble.left.and.text.bubble.right", title: "Coach needs the cloud",
                                   text: "The coach runs on your own server, so your AI key never sits in the app. Set up Cloud in Settings first.")
                    } else if conversation.isEmpty {
                        intro
                    }
                    ForEach(conversation) { message in
                        bubble(message).id(message.id)
                    }
                    if waiting {
                        HStack(spacing: DS.Space.s) {
                            ProgressView().controlSize(.small)
                            Text("Thinking")
                                .textStyle(.caption)
                                .foregroundStyle(DS.Colors.secondary)
                        }
                        .id("waiting")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.side)
                .padding(.vertical, DS.Space.m)
            }
            .onChange(of: conversation.count) { _, _ in
                if let last = conversation.last?.id {
                    withAnimation(DS.Motion.spring) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ScreenHeader(title: "Coach", isSheet: true) {
                IconButton(systemName: "xmark", label: "Close") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .monoSheet()
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Ask about\nyour data")
                .textStyle(.display)
                .foregroundStyle(DS.Colors.primary)
            Text("The coach sees your last 14 days of summaries. It gives general guidance, not medical advice.")
                .textStyle(.body)
                .foregroundStyle(DS.Colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .buttonStyle(.secondaryPill)
                }
            }
            .padding(.top, DS.Space.s)
        }
    }

    @ViewBuilder
    private func bubble(_ message: CloudManager.ChatMessage) -> some View {
        if message.role == "user" {
            Text(message.content)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.onPrimary)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 12)
                .background(DS.Colors.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You: \(message.content)")
        } else {
            Text(message.content)
                .textStyle(.body)
                .foregroundStyle(DS.Colors.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Coach: \(message.content)")
        }
    }

    /// The text field and send button, pinned above the keyboard.
    private var composer: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask the coach", text: $draft, axis: .vertical)
                .textStyle(.body)
                .lineLimit(1...4)
                .focused($typing)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 12)
                .background(DS.Colors.border, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onSubmit { send(draft) }
            IconButton(systemName: "arrow.up", label: "Send") { send(draft) }
                .disabled(waiting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(!cloud.isSignedIn)
        .padding(.horizontal, DS.Space.side)
        .padding(.vertical, DS.Space.s)
        .background(DS.Colors.sheet)
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !waiting, cloud.isSignedIn else { return }
        draft = ""
        conversation.append(CloudManager.ChatMessage(role: "user", content: question))
        waiting = true
        let sent = conversation
        Task {
            let answer = await cloud.askCoach(sent)
            conversation.append(CloudManager.ChatMessage(role: "assistant", content: answer))
            waiting = false
        }
    }
}
