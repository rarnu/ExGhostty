//
//  TerminalTabContainerView.swift
//  ExGhostty_iPad
//
//  Right side of the split view: a tab bar plus the tab contents. Every tab
//  stays in the view hierarchy (hidden with opacity) so its terminal session
//  keeps running while another tab is active. Tabs come in two kinds: SSH
//  terminals and in-app browser tabs (opened from port-forward rules).
//  With no tabs open, an intro view is shown instead.
//

import SwiftUI

struct TerminalTabContainerView: View {
    @EnvironmentObject private var tabStore: TerminalTabStore

    var body: some View {
        VStack(spacing: 0) {
            if tabStore.tabs.isEmpty {
                IntroView()
            } else {
                tabBar
                Divider()
                ZStack {
                    ForEach(tabStore.tabs) { tab in
                        Group {
                            switch tab.kind {
                            case .terminal:
                                TerminalSessionView(tab: tab)
                            case .browser:
                                if let url = tab.browserURL {
                                    BrowserTabView(url: url)
                                }
                            }
                        }
                        .opacity(tab.id == tabStore.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == tabStore.activeTabID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabStore.tabs) { tab in
                    TabButton(
                        tab: tab,
                        isActive: tab.id == tabStore.activeTabID,
                        onSelect: { tabStore.activate(tab) },
                        onClose: { tabStore.close(tab) }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.11))
    }
}

private struct TabButton: View {
    let tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind == .browser ? "globe" : "terminal")
                .font(.system(size: 11))
            Text(tab.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 150)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.teal : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.teal.opacity(0.15) : Color(white: 0.16))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Shown on the right side when no terminal tab is open.
private struct IntroView: View {
    @StateObject private var l10n = LocalizationManager.shared

    private let features: [(icon: String, title: String)] = [
        ("terminal", "SSH 终端"),
        ("folder", "SFTP 文件管理"),
        ("rectangle.split.3x1", "Session 复用"),
        ("network", "端口占用"),
        ("shippingbox", "Docker 管理"),
        ("gauge", "系统监控"),
        ("sparkles", "AI 助手"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let icon = UIImage.appIcon() {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.teal)
                }
                Text("ExGhostty")
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(L("功能完整的 SSH 客户端\n支持密钥认证、跳板机与连接分组"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                    spacing: 12
                ) {
                    ForEach(features, id: \.title) { feature in
                        Label(L(feature.title), systemImage: feature.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 340)
                .padding(.top, 8)
                Text(L("从左侧栏选择或新增一个 SSH 连接开始"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
