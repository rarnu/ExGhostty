import SwiftUI

/// 自定义标签栏，显示在右侧终端区域顶部
struct TabBarView: View {
    /// 强制刷新 ID（每次 rebuildTabBar 递增，让 SwiftUI 重新渲染）
    let viewID: Int

    /// 当前标签组的所有窗口
    let windows: [NSWindow]

    /// 当前选中的窗口
    let selectedWindow: NSWindow?

    /// 背景不透明度（0~1，来自 background-opacity 配置）
    let backgroundOpacity: CGFloat

    /// 回调
    var onSelectTab: ((NSWindow) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: ((NSWindow) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // 标签按钮
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(windows, id: \.self) { window in
                        tabButton(for: window)
                    }
                }
            }
        }
        .id(viewID)
        .frame(height: 28)
        .background(
            // 使用 config 的 backgroundOpacity 控制标签栏背景透明度
            VisualEffectView(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            ).opacity(max(0.1, backgroundOpacity))
        )
    }

    private func tabButton(for window: NSWindow) -> some View {
        let isSelected = window == selectedWindow
        let title = window.title.isEmpty ? "Terminal" : window.title

        return HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 150)

            if windows.count > 1 {
                Button(action: { onCloseTab?(window) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color(.selectedControlColor).opacity(0.3) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectTab?(window)
        }
    }
}

// MARK: - NSVisualEffectView 的 SwiftUI 包装

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
