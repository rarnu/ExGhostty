import AppKit
import SwiftUI

/// 右侧功能面板内容，目前只显示标题栏。
struct FunctionPanelView: View {
    let feature: RightSidebarFeature?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topToolbar: some View {
        HStack(spacing: 0) {
            Text(feature?.title ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
    }
}
