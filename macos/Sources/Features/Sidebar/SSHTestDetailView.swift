import SwiftUI
import AppKit

/// 测试连接详情弹窗视图
struct SSHTestDetailView: View {
    let config: SSHTestConfig
    let onComplete: ((Bool) -> Void)?

    @State private var logs: [SSHTestLogItem] = []
    @State private var isFinished = false
    @State private var isSuccess = false
    @State private var finalMessage = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            logList
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 680, height: 420)
        .background(Color(.windowBackgroundColor))
        .onAppear(perform: startTest)
        .onDisappear {
            task?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isFinished ? (isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill") : "bolt.horizontal.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(isFinished ? (isSuccess ? .green : .red) : .accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("测试连接")
                    .font(.system(size: 15, weight: .semibold))
                Text(targetDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !isFinished {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var targetDescription: String {
        let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
        var text = "\(userPrefix)\(config.host):\(config.port)"
        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            text += " via \(jump.name)"
        }
        return text
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(logs) { item in
                        logRow(item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .background(Color(.textBackgroundColor))
            .cornerRadius(6)
            .onChange(of: logs.count) { _ in
                if let last = logs.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func logRow(_ item: SSHTestLogItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            switch item.kind {
            case .step:
                Image(systemName: "number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 14, height: 14)
            case .log:
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 4, height: 4)
                    .cornerRadius(2)
                    .padding(.top, 5)
                    .padding(.leading, 5)
            }

            Text(item.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(item.kind == .step ? .primary : .secondary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isFinished {
                HStack(spacing: 6) {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isSuccess ? .green : .red)
                    Text(finalMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSuccess ? .green : .red)
                        .lineLimit(2)
                }
            } else {
                Text("正在测试，请稍候...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("关闭") {
                onComplete?(isSuccess)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isFinished)
        }
    }

    // MARK: - Actions

    private func startTest() {
        logs.removeAll()
        isFinished = false
        isSuccess = false
        finalMessage = ""

        task = Task {
            let stream = SSHTester.stream(config: config)
            for await event in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    switch event {
                    case .step(let text):
                        logs.append(SSHTestLogItem(kind: .step, text: text))
                    case .log(let text):
                        logs.append(SSHTestLogItem(kind: .log, text: text))
                    case .success(let message):
                        isSuccess = true
                        finalMessage = message
                        isFinished = true
                    case .failure(let message):
                        isSuccess = false
                        finalMessage = message
                        isFinished = true
                    }
                }
            }
        }
    }

    private func dismiss() {
        if let window = NSApp.keyWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet)
        } else {
            NSApp.keyWindow?.close()
        }
    }
}

// MARK: - Log Item

private struct SSHTestLogItem: Identifiable {
    let id = UUID()
    let kind: Kind
    let text: String

    enum Kind {
        case step
        case log
    }
}
