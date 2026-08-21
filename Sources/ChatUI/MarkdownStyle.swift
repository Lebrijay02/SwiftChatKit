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

    public var bodyFontSize: CGFloat = PlatformFont.chatBodySize
    public var textColor: PlatformColor
    public var secondaryColor: PlatformColor
    public var accentColor: PlatformColor
    public var codeBackground: PlatformColor
    public var quoteBarColor: PlatformColor
    public var highlightColor: PlatformColor
    public var dividerColor: PlatformColor
    /// Fill for the code block's header strip.
    public var codeHeaderBackground: PlatformColor

    /// Multipliers for H1…H6.
    public var headingScales: [CGFloat] = [1.7, 1.4, 1.2, 1.08, 1.0, 0.95]

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

    public static func from(palette: ChatPalette,
                            appearanceIsDark: Bool,
                            bodyFontSize: CGFloat = PlatformFont.chatBodySize) -> MarkdownStyle {
        MarkdownStyle(
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
    }
}
