//
//  Platform.swift
//  SwiftChatKit
//
//  AppKit and UIKit spell the same things differently. Everything the renderer
//  needs from either is funnelled through here, so the views below read as one
//  codebase instead of two interleaved ones.
//

import SwiftUI

#if canImport(AppKit)
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
#elseif canImport(UIKit)
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
#endif

extension PlatformFont {

    public static var chatBodySize: CGFloat {
        #if canImport(AppKit)
        NSFont.systemFontSize
        #else
        UIFont.systemFontSize
        #endif
    }

    public static func chatSystem(size: CGFloat, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        systemFont(ofSize: size, weight: weight)
    }

    public static func chatMono(size: CGFloat) -> PlatformFont {
        #if canImport(AppKit)
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }

    /// Returns this font with `trait` added, or itself when the family has no
    /// such face — a missing bold is a styling miss, not a reason to fail.
    func addingChatTrait(_ trait: ChatFontTrait) -> PlatformFont {
        #if canImport(AppKit)
        let symbolic: NSFontDescriptor.SymbolicTraits = trait == .bold ? .bold : .italic
        let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(symbolic))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        let symbolic: UIFontDescriptor.SymbolicTraits = trait == .bold ? .traitBold : .traitItalic
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(symbolic)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

enum ChatFontTrait {
    case bold
    case italic
}

public extension PlatformColor {
    /// Bridges a SwiftUI `Color` into the platform type the text stack needs.
    static func from(chat color: Color) -> PlatformColor {
        PlatformColor(color)
    }
}
