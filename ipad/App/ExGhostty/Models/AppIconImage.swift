//
//  AppIconImage.swift
//  ExGhostty_iPad
//
//  Shared app-icon loader. App icons compiled from the asset catalog are
//  NOT reachable via UIImage(named: "AppIcon"); the real file names live in
//  Info.plist's CFBundleIcons. Used by the About pane and the no-tab intro
//  view so both show the actual app icon.
//

import UIKit

extension UIImage {
    /// The app's own icon, resolved from CFBundleIcons (cached after first
    /// lookup). Falls back to the "AppIcon" name just in case.
    static func appIcon() -> UIImage? {
        if let cached = cachedAppIcon { return cached }
        var icon: UIImage?
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            for name in files.reversed() {
                if let image = UIImage(named: name) {
                    icon = image
                    break
                }
            }
        }
        if icon == nil { icon = UIImage(named: "AppIcon") }
        cachedAppIcon = icon
        return icon
    }
}

private var cachedAppIcon: UIImage?
