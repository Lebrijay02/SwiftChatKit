//
//  ChatPalette.swift
//  SwiftChatKit
//
//  The renderer's entire theming surface. A host with its own theme builds one of
//  these; a host without one gets `.default`, which is drawn from the system's
//  semantic colors and therefore already tracks light and dark mode.
//

import SwiftUI

/// `Hashable` so the renderer can tell one theme from another cheaply. It cannot do that
/// from the platform colors a palette is converted into: a SwiftUI `Color` that follows
/// the system appearance becomes a dynamic catalog color, and every conversion produces a
/// fresh one that describes itself with a new UUID.
public struct ChatPalette: Sendable, Hashable {

    public var accent: Color
    public var background: Color
    /// Fill behind inline code and fenced blocks.
    public var codeBackground: Color
    /// Fill for the code block's header strip.
    public var header: Color
    public var divider: Color
    public var outline: Color
    public var primaryText: Color
    public var secondaryText: Color

    public init(accent: Color,
                background: Color,
                codeBackground: Color,
                header: Color,
                divider: Color,
                outline: Color,
                primaryText: Color,
                secondaryText: Color) {
        self.accent = accent
        self.background = background
        self.codeBackground = codeBackground
        self.header = header
        self.divider = divider
        self.outline = outline
        self.primaryText = primaryText
        self.secondaryText = secondaryText
    }

    /// Semantic colors only, so a host that never sets a palette still gets a
    /// renderer that follows the system appearance.
    public static let `default` = ChatPalette(
        accent: .accentColor,
        background: .clear,
        codeBackground: Color.gray.opacity(0.15),
        header: Color.gray.opacity(0.22),
        divider: Color.gray.opacity(0.35),
        outline: Color.gray.opacity(0.3),
        primaryText: .primary,
        secondaryText: .secondary)
}

// MARK: - Environment

private struct ChatPaletteKey: EnvironmentKey {
    static let defaultValue = ChatPalette.default
}

public extension EnvironmentValues {
    var chatPalette: ChatPalette {
        get { self[ChatPaletteKey.self] }
        set { self[ChatPaletteKey.self] = newValue }
    }
}

public extension View {
    /// Themes every SwiftChatKit view below this one.
    func chatPalette(_ palette: ChatPalette) -> some View {
        environment(\.chatPalette, palette)
    }
}
