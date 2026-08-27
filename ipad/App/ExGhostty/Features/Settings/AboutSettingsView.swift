//
//  AboutSettingsView.swift
//  ExGhostty_iPad
//
//  Settings "About" pane, modeled on the Mac version's About dialog
//  (macos/Sources/Features/About/AboutView.swift): app icon, name,
//  version, author and tappable project links. The Mac dialog's OK
//  button is dropped — the settings page already has a back button.
//

import SwiftUI
import UIKit

struct AboutSettingsView: View {
    @StateObject private var l10n = LocalizationManager.shared

    private struct AboutLink: Identifiable {
        let id = UUID()
        let name: String
        let url: String
    }

    private let links: [AboutLink] = [
        AboutLink(name: "ExGhostty", url: "https://github.com/rarnu/exghostty"),
        AboutLink(name: "Ghostty", url: "https://github.com/ghostty-org/ghostty"),
        AboutLink(name: "XTOP", url: "https://github.com/rarnu/xtop"),
        AboutLink(name: "SwiftTerm", url: "https://github.com/migueldeicaza/SwiftTerm"),
    ]

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 头部：图标 + 名称 / 版本 / 简介（对齐 Mac 版布局）
            HStack(alignment: .center, spacing: 20) {
                if let icon = UIImage.appIcon() {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("ExGhostty")
                        .font(.system(size: 22, weight: .bold))
                    Text(L("版本") + " \(version)")
                        .font(.subheadline)
                    Text(L("一款基于 Ghostty 的全新 SSH 工具"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            infoRow(label: L("作者"), value: "rarnu")

            Divider().overlay(Color.gray.opacity(0.3))

            Text(L("项目链接"))
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 14) {
                ForEach(links) { link in
                    HStack(spacing: 16) {
                        Text(link.name)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 96, alignment: .leading)
                        if let url = URL(string: link.url) {
                            Link(destination: url) {
                                Text(link.url)
                                    .font(.subheadline)
                                    .underline()
                                    .foregroundStyle(.teal)
                            }
                        } else {
                            Text(link.url)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    AboutSettingsView()
        .padding(24)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
