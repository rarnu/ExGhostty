import SwiftUI

/// 自定义标签栏，显示在右侧终端区域顶部
struct TabBarView: View {
    @Environment(\.appTheme) private var appTheme

    /// 强制刷新 ID（每次 rebuildTabBar 递增，让 SwiftUI 重新渲染）
    let viewID: Int

    /// 当前标签组的所有窗口
    let windows: [NSWindow]

    /// 当前选中的窗口
    let selectedWindow: NSWindow?

    /// 与终端保持一致的背景色（已包含 background-opacity alpha）
    let backgroundColor: NSColor

    /// 回调
    var onSelectTab: ((NSWindow) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: ((NSWindow) -> Void)?

    var body: some View {
        ZStack {
            // 背景色由 NSHostingView 的 layer 提供，避免透明 layer 在首次 resize 时产生未初始化像素。
            ProportionalTabLayout {
                ForEach(windows, id: \.self) { window in
                    tabButton(for: window)
                }
            }
        }
        .id(viewID)
        .frame(height: 36)
    }

    private func tabButton(for window: NSWindow) -> some View {
        let isSelected = window == selectedWindow
        let title = window.title.isEmpty ? "Terminal" : window.title

        return HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(appTheme.foreground)
                .lineLimit(1)

            if windows.count > 1 {
                Button(action: { onCloseTab?(window) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(appTheme.secondaryForeground.opacity(0.6))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(isSelected ? appTheme.selectionBackground : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectTab?(window)
        }
    }
}

/// 标签等比缩放布局：各标签先按内容的理想宽度排列（宽度随文本变化）；
/// 总宽度超过可用宽度时，所有标签按同一比例缩小（超出的部分由文本截断吸收）。
/// 标签增删、标题变化、区域宽度变化都会触发布局重算。
private struct ProportionalTabLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let totalIdealWidth = idealSizes.map(\.width).reduce(0, +)
        let maxHeight = idealSizes.map(\.height).max() ?? 0
        return CGSize(
            width: min(totalIdealWidth, proposal.width ?? totalIdealWidth),
            height: maxHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let idealWidths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let totalIdealWidth = idealWidths.reduce(0, +)
        // 总宽度超出可用宽度时，各标签按同一比例缩小。
        let scale = totalIdealWidth > bounds.width && totalIdealWidth > 0
            ? bounds.width / totalIdealWidth
            : 1

        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = idealWidths[index] * scale
            // 标签高度取自身内容高度，在栏内垂直居中。
            let childSize = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let height = min(childSize.height, bounds.height)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + (bounds.height - height) / 2),
                proposal: ProposedViewSize(width: width, height: height)
            )
            x += width
        }
    }
}
