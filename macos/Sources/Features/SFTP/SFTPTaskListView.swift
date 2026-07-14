import AppKit
import SwiftUI
import Combine

/// SFTP 传输任务列表窗口内容。
struct SFTPTaskListView: View {
    @StateObject private var manager = SFTPTransferManager.shared
    let connection: SSHConnection?

    private var displayedTasks: [SFTPTask] {
        guard let connection else { return manager.tasks }
        return manager.tasks.filter { $0.connection.id == connection.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            taskList
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if displayedTasks.isEmpty {
                    Text("暂无传输任务")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(displayedTasks) { task in
                        SFTPTaskRow(task: task)
                            .frame(maxWidth: .infinity)
                        Divider()
                    }
                }
            }
        }
    }

    private var bottomToolbar: some View {
        HStack {
            Spacer()
            Button("清空全部") {
                manager.clearCompleted(for: connection)
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(displayedTasks.allSatisfy { !$0.isCompleted })
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.controlBackgroundColor).opacity(0.2))
    }
}

/// 单个任务行。
private struct SFTPTaskRow: View {
    @ObservedObject var task: SFTPTask

    var body: some View {
        HStack(spacing: 8) {
            directionIcon
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var directionIcon: some View {
        let icon = task.type == .upload ? "arrow.up" : "arrow.down"
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(task.type == .upload ? .orange : .accentColor)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            switch task.state {
            case .running:
                Button(action: { SFTPTransferManager.shared.pauseTask(task) }) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("暂停")
            case .paused:
                Button(action: { SFTPTransferManager.shared.resumeTask(task) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("恢复")
            default:
                EmptyView()
            }

            Button(action: { SFTPTransferManager.shared.cancelTask(task) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .foregroundColor(.secondary)
    }

    private var statusText: String {
        switch task.state {
        case .pending:   return "等待中"
        case .running:   return String(format: "%.0f%%", task.progress * 100)
        case .paused:    return "已暂停"
        case .completed: return "已完成"
        case .failed:    return task.errorMessage ?? "失败"
        case .cancelled: return "已取消"
        }
    }
}
