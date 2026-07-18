import SwiftUI
import AppKit

/// “关于 ExGhostty”窗口内容：图标、版本信息、项目链接。
/// 链接均可点击并在浏览器中打开。
struct AboutView: View {
    var onClose: () -> Void = {}

    private struct AboutLink: Identifiable {
        let id = UUID()
        let name: String
        let url: String
    }

    private let links: [AboutLink] = [
        AboutLink(name: "ExGhostty", url: "https://github.com/rarnu/exghostty"),
        AboutLink(name: "Ghostty", url: "https://github.com/ghostty-org/ghostty"),
        AboutLink(name: "XTOP", url: "https://github.com/rarnu/xtop"),
    ]

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：图标 + 名称 / 版本 / 简介
            HStack(alignment: .center, spacing: 28) {
                ghosttyIconImage()
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("ExGhostty")
                        .font(.system(size: 24, weight: .bold))

                    Text(String(format: "Version: %@".localized, version))
                        .font(.system(size: 15))

                    Text("A brand-new SSH tool based on Ghostty".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Divider()

            // 中部：项目链接
            VStack(spacing: 20) {
                ForEach(links) { link in
                    HStack(spacing: 16) {
                        Text(link.name)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 96, alignment: .leading)

                        if let url = URL(string: link.url) {
                            Link(destination: url) {
                                Text(link.url)
                                    .font(.system(size: 15))
                                    .underline()
                                    .foregroundColor(.primary)
                            }
                        } else {
                            Text(link.url)
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            // 底部：OK 按钮
            HStack {
                Spacer()
                Button("OK".localized) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 620)
    }
}
