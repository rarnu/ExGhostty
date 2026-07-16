import AppKit
import SwiftUI

/// 系统监控面板状态。
private enum SystemMonitorState {
    case checking
    case notInstalled
    case running
}

/// 右侧栏“系统监控”功能面板。
struct SystemMonitorPanelView: View {
    let terminalController: TerminalController?

    @StateObject private var service = SystemMonitorService()
    @State private var state: SystemMonitorState = .checking

    var body: some View {
        Group {
            switch state {
            case .checking:
                ProgressView()
                    .scaleEffect(0.8)
            case .notInstalled:
                notInstalledView
            case .running:
                monitorContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startService()
        }
        .onDisappear {
            service.stop()
        }
    }

    // MARK: - 安装提示

    private var notInstalledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("xtop not detected".localized)
                .font(.system(size: 14, weight: .medium))
            Text("System Monitor requires xtop to be installed".localized)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button("Go to Install".localized) {
                openXTopHomepage()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
    }

    private func openXTopHomepage() {
        guard let url = URL(string: "https://github.com/rarnu/xtop") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 监控内容

    private var monitorContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                cpuCard
                memoryCard
                diskCard
                networkCard
                gpuCard
                processCard
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - CPU

    private var cpuCard: some View {
        MonitorCard(title: "CPU", headerValue: service.latestOutput?.cpu?.Overall.formattedPercent()) {
            if let cpu = service.latestOutput?.cpu {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(cpu.Overall / 100.0, 0), 1))
                        .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                    if !cpu.PerCore.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 28), spacing: 4), count: min(cpu.PerCore.count, 8)), spacing: 4) {
                            ForEach(Array(cpu.PerCore.enumerated()), id: \.offset) { idx, value in
                                VStack(spacing: 2) {
                                    Text("\(idx)")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                    GeometryReader { geo in
                                        ZStack(alignment: .bottom) {
                                            Rectangle()
                                                .fill(Color.secondary.opacity(0.2))
                                            Rectangle()
                                                .fill(Color.accentColor)
                                                .frame(height: geo.size.height * CGFloat(min(max(value / 100.0, 0), 1)))
                                        }
                                        .cornerRadius(2)
                                    }
                                    .frame(height: 32)
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - Memory

    private var memoryCard: some View {
        MonitorCard(title: "Memory", headerValue: service.latestOutput?.mem.map { $0.Used.formattedBytes() + " / " + $0.Total.formattedBytes() }) {
            if let mem = service.latestOutput?.mem {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                            let usedRatio = mem.Total > 0 ? Double(mem.Used) / Double(mem.Total) : 0
                            let cachedRatio = mem.Total > 0 ? Double(mem.Cached) / Double(mem.Total) : 0
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: geo.size.width * CGFloat(usedRatio))
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: geo.size.width * CGFloat(cachedRatio))
                                .offset(x: geo.size.width * CGFloat(usedRatio))
                        }
                        .cornerRadius(3)
                    }
                    .frame(height: 12)

                    HStack(spacing: 16) {
                        MemoryLegendItem(color: .orange, label: "Used", value: mem.Used.formattedBytes())
                        MemoryLegendItem(color: .green, label: "Cached", value: mem.Cached.formattedBytes())
                        MemoryLegendItem(color: .secondary.opacity(0.3), label: "Free", value: mem.Free.formattedBytes())
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - Disk

    private var diskCard: some View {
        MonitorCard(title: "Disk") {
            if let mounts = service.latestOutput?.disk?.Mounts, !mounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mounts) { mount in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(mount.Mountpoint)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(mount.UsedPercent.formattedPercent()) · \(mount.Used.formattedBytes()) / \(mount.Total.formattedBytes())")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            ProgressView(value: min(max(mount.UsedPercent / 100.0, 0), 1))
                                .progressViewStyle(LinearProgressViewStyle(tint: mount.UsedPercent > 90 ? .red : .accentColor))
                            HStack(spacing: 12) {
                                Label(mount.ReadPerSec.formattedBytesPerSecond(), systemImage: "arrow.down.circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                                Label(mount.WritePerSec.formattedBytesPerSecond(), systemImage: "arrow.up.circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Spacer()
                            }
                        }
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - GPU

    private var gpuCard: some View {
        MonitorCard(title: "GPU") {
            if let gpu = service.latestOutput?.gpu {
                if gpu.Available, let cards = gpu.Cards, !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(cards.count > 1 ? "[#\(index + 1)] \(card.Name)" : card.Name)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("GPU Load".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(card.LoadPct.formattedPercent())
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    ProgressView(value: min(max(card.LoadPct / 100.0, 0), 1))
                                        .progressViewStyle(LinearProgressViewStyle(tint: .purple))
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("VRAM Usage".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        if card.MemTotal > 0 {
                                            Text("\(gpuMemText(for: card)) (\(String(format: "%.2f", Double(card.MemUsed) / Double(card.MemTotal) * 100))%)")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text(gpuMemText(for: card))
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    if card.MemTotal > 0 {
                                        ProgressView(value: min(max(Double(card.MemUsed) / Double(card.MemTotal), 0), 1))
                                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                    }
                                }

                                HStack(spacing: 12) {
                                    Text(card.TempC.formattedCelsius())
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Text(card.PowerW.formattedWatts())
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                        }
                    }
                } else {
                    Text(gpu.Message ?? "GPU unavailable".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - Network

    private var networkCard: some View {
        MonitorCard(title: "Network", headerValue: service.latestOutput?.net.map { "↑ " + $0.UploadPerSec.formattedBytesPerSecond() + "  ↓ " + $0.DownloadPerSec.formattedBytesPerSecond() }) {
            if let net = service.latestOutput?.net {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Upload")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(net.UploadPerSec.formattedBytesPerSecond())
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.green)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(net.DownloadPerSec.formattedBytesPerSecond())
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        Spacer()
                    }

                    if let topProcs = net.TopProcs, !topProcs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(topProcs.prefix(5)) { proc in
                                HStack {
                                    Text(proc.Command)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("↑ \(proc.UploadPerSec.formattedBytesPerSecond())  ↓ \(proc.DownloadPerSec.formattedBytesPerSecond())")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - Process

    private var processCard: some View {
        MonitorCard(title: "Processes", headerValue: service.latestOutput?.proc.map { "\($0.Total) total" }) {
            if let proc = service.latestOutput?.proc {
                VStack(alignment: .leading, spacing: 8) {
                    if let topCPU = proc.TopCPU, !topCPU.isEmpty {
                        ProcessSection(title: "Top CPU", procs: topCPU) { $0.CPU.formattedPercent() }
                    }
                    if let topMem = proc.TopMem, !topMem.isEmpty {
                        ProcessSection(title: "Top Memory", procs: topMem) { $0.MemRSS.formattedBytes() }
                    }
                    if let topDisk = proc.TopDisk, !topDisk.isEmpty {
                        ProcessSection(title: "Top Disk", procs: topDisk) { "\($0.CPU.formattedPercent())" }
                    }
                }
            } else {
                EmptyDataHint()
            }
        }
    }

    // MARK: - Service lifecycle

    private func startService() {
        guard state != .running else { return }
        state = .checking

        Task {
            let connection = terminalController?.sshConnection
            let available = await SystemMonitorService.checkXTopAvailable(connection: connection)
            await MainActor.run {
                if available {
                    self.state = .running
                    self.service.start(connection: connection)
                } else {
                    self.state = .notInstalled
                }
            }
        }
    }
}

// MARK: - Card container

private struct MonitorCard<Content: View>: View {
    let title: String
    var headerValue: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let headerValue {
                    Text(headerValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            content
        }
        .padding(10)
        .background(Color.black.opacity(0.15))
        .cornerRadius(8)
    }
}

private struct EmptyDataHint: View {
    var body: some View {
        Text("Waiting for data…".localized)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }
}

private struct MemoryLegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10))
        }
    }
}

private struct ProcessSection: View {
    let title: String
    let procs: [XTopProcInfo]
    let valueFormatter: (XTopProcInfo) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            ForEach(procs.prefix(5)) { proc in
                HStack {
                    Text(proc.Command)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Spacer()
                    Text(valueFormatter(proc))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private func gpuMemText(for card: XTopGPUCard) -> String {
    if card.MemTotal == 0 {
        return card.MemUsed > 0 ? card.MemUsed.formattedBytes() : "N/A"
    }
    return "\(card.MemUsed.formattedBytes()) / \(card.MemTotal.formattedBytes())"
}
