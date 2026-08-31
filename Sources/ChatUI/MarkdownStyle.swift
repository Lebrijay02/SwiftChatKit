//
//  MarkdownStyle.swift
//  SwiftChatKit
//
//  The palette resolved into the concrete fonts and colors the attributed-string
//  builder works in. Kept separate from `ChatPalette` because the builder runs
//  below SwiftUI and cannot resolve a `Color` itself.
//

import SwiftUI

public struct MarkdownStyle {

    // Changing any of these by hand drops the recorded identity, so a style adjusted
    // after it was built is no longer mistaken for the one it was built from.
    public var bodyFontSize: CGFloat = PlatformFont.chatBodySize { didSet { identity = "" } }
    public var textColor: PlatformColor { didSet { identity = "" } }
    public var secondaryColor: PlatformColor { didSet { identity = "" } }
    public var accentColor: PlatformColor { didSet { identity = "" } }
    public var codeBackground: PlatformColor { didSet { identity = "" } }
    public var quoteBarColor: PlatformColor { didSet { identity = "" } }
    public var highlightColor: PlatformColor { didSet { identity = "" } }
    public var dividerColor: PlatformColor { didSet { identity = "" } }
    /// Fill for the code block's header strip.
    public var codeHeaderBackground: PlatformColor { didSet { identity = "" } }

    /// Multipliers for H1…H6.
    public var headingScales: [CGFloat] = [1.7, 1.4, 1.2, 1.08, 1.0, 0.95] { didSet { identity = "" } }

    /// What this style was built from, when that is knowable — see ``key(for:)``.
    /// Empty for a style assembled colour by colour, which falls back to describing them.
    var identity: String = ""

    public init(bodyFontSize: CGFloat = PlatformFont.chatBodySize,
                textColor: PlatformColor,
                secondaryColor: PlatformColor,
                accentColor: PlatformColor,
                codeBackground: PlatformColor,
                quoteBarColor: PlatformColor,
                highlightColor: PlatformColor,
                dividerColor: PlatformColor,
                codeHeaderBackground: PlatformColor,
                headingScales: [CGFloat] = [1.7, 1.4, 1.2, 1.08, 1.0, 0.95]) {
        self.bodyFontSize = bodyFontSize
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.codeBackground = codeBackground
        self.quoteBarColor = quoteBarColor
        self.highlightColor = highlightColor
        self.dividerColor = dividerColor
        self.codeHeaderBackground = codeHeaderBackground
        self.headingScales = headingScales
    }

    /// Cheap identity for a style, used to notice theme and appearance changes — every
    /// attribute in a rendered message depends on these, so nothing survives one.
    ///
    /// Describing the colours is the fallback rather than the rule because a dynamic
    /// colour's description carries a per-instance UUID: two styles built from the same
    /// palette would never match, and every cache keyed on this would miss every time.
    static func key(for style: MarkdownStyle) -> String {
        style.identity.isEmpty
            ? "\(style.bodyFontSize)-\(style.textColor)-\(style.codeBackground)-\(style.accentColor)"
            : style.identity
    }

    public static func from(palette: ChatPalette,
                            appearanceIsDark: Bool,
                            bodyFontSize: CGFloat = PlatformFont.chatBodySize) -> MarkdownStyle {
        var style = MarkdownStyle(
            bodyFontSize: bodyFontSize,
            textColor: PlatformColor.from(chat: palette.primaryText),
            secondaryColor: PlatformColor.from(chat: palette.secondaryText),
            accentColor: PlatformColor.from(chat: palette.accent),
            codeBackground: PlatformColor.from(chat: palette.codeBackground),
            quoteBarColor: PlatformColor.from(chat: palette.secondaryText).withAlphaComponent(0.4),
            // Yellow behind dark text needs less alpha than behind light text to
            // read as a highlight rather than a blot.
            highlightColor: PlatformColor.systemYellow.withAlphaComponent(appearanceIsDark ? 0.35 : 0.45),
            dividerColor: PlatformColor.from(chat: palette.divider),
            codeHeaderBackground: PlatformColor.from(chat: palette.header))
        style.identity = "\(palette.hashValue)-\(appearanceIsDark)-\(bodyFontSize)"
        return style
    }
}
