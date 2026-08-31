//
//  HistoryView.swift
//  ChatDemo
//
//  Lists what `ChatHistoryStore` has on disk. Tapping a row loads it into the
//  live session in place; nothing here talks to the backend.
//

import SwiftUI
import ChatCore

struct HistoryView: View {

    let historyStore: ChatHistoryStore
    let session: ChatSession
    let onDismiss: () -> Void

    @State private var sessions: [StoredSession] = []

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView("No saved chats", systemImage: "clock")
                } else {
                    List {
                        ForEach(sessions) { stored in
                            Button {
                                session.load(stored)
                                onDismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stored.title)
                                        .foregroundStyle(.primary)
                                    Text(stored.updatedAt, format: .dateTime)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        // A macOS sheet with no intrinsic size shrinks to fit its toolbar,
        // squeezing the list to nothing — force a reasonable window size.
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .onAppear { sessions = historyStore.loadAll() }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            historyStore.delete(sessions[index].id)
        }
        sessions = historyStore.loadAll()
    }
}
