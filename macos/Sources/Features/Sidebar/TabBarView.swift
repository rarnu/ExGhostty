import SwiftUI

/// 自定义标签栏，显示在右侧终端区域顶部
struct TabBarView: View {
    /// 当前标签组的所有窗口
    let windows: [NSWindow]

    /// 当前选中的窗口
    let selectedWindow: NSWindow?

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

            // 新建标签按钮
            Button(action: { onNewTab?() }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("New Tab")
            .padding(.horizontal, 4)
        }
        .frame(height: 28)
        .background(Color(.controlBackgroundColor).opacity(0.5))
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
