//
//  PermissionRequestView.swift
//  SwiftChatKit
//
//  The approval card shown above the input while the agent loop is paused on a
//  mutating tool call or a plan-mode exit.
//

import SwiftUI
import ChatCore

public struct PermissionRequestView: View {

    @Environment(\.chatPalette) private var palette

    public let request: PermissionRequest
    public let permissions: PermissionService

    /// Tools whose detail is a diff rather than prose. Defaults to the built-in
    /// file tools; a host with its own editing tool adds it here.
    public var diffToolNames: Set<String>
    public var wholeFileToolNames: Set<String>

    public init(request: PermissionRequest,
                permissions: PermissionService,
                diffToolNames: Set<String> = ["editFile"],
                wholeFileToolNames: Set<String> = ["writeFile"]) {
        self.request = request
        self.permissions = permissions
        self.diffToolNames = diffToolNames
        self.wholeFileToolNames = wholeFileToolNames
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: request.kind == .plan ? "list.clipboard" : "lock.shield")
                    .foregroundStyle(palette.accent)
                Text(request.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(2)
                Spacer()
            }

            if !request.detail.isEmpty {
                ScrollView { detail }
                    .frame(maxHeight: request.kind == .plan ? 220 : 180)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.codeBackground.opacity(0.6))
                    )
            }

            buttons
        }
        .font(.footnote)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background)
                .stroke(palette.outline)
        )
    }

    @ViewBuilder
    private var detail: some View {
        if wholeFileToolNames.contains(request.toolName) {
            FileDiffPreviewView(title: request.title, writeFileContent: request.detail)
        } else if diffToolNames.contains(request.toolName) {
            FileDiffPreviewView(title: request.title, rawDiff: request.detail)
        } else {
            // A plan reads as prose; anything else is arguments or a command line,
            // which only make sense monospaced.
            Text(request.detail)
                .font(request.kind == .plan ? .callout : .callout.monospaced())
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            if request.kind == .plan {
                approveButton("Approve plan", prominent: true) { permissions.resolve(.allowOnce) }
                approveButton("Keep planning") { permissions.resolve(.deny) }
            } else {
                approveButton("Allow", prominent: true) { permissions.resolve(.allowOnce) }
                approveButton("Always allow") { permissions.resolve(.alwaysAllow) }
                approveButton("Deny") { permissions.resolve(.deny) }
            }
            Spacer()
        }
    }

    private func approveButton(_ label: String,
                               prominent: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(prominent ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(prominent ? palette.accent.opacity(0.9)
                                        : palette.codeBackground.opacity(0.8))
                )
                .foregroundStyle(prominent ? Color.white : palette.primaryText)
        }
        .buttonStyle(.plain)
    }
}
