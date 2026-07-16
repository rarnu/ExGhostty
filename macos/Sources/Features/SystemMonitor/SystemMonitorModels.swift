import Foundation

/// xtop `--json --stream` 输出的顶层结构。
struct XTopOutput: Codable {
    let time: Date?
    let cpu: XTopCPU?
    let mem: XTopMem?
    let disk: XTopDisk?
    let net: XTopNet?
    let gpu: XTopGPU?
    let proc: XTopProc?
}

struct XTopCPU: Codable {
    let Overall: Double
    let PerCore: [Double]
}

struct XTopMem: Codable {
    let Total: UInt64
    let Used: UInt64
    let Cached: UInt64
    let Free: UInt64
}

struct XTopDisk: Codable {
    let Mounts: [XTopDiskMount]
    let TotalBytes: UInt64?
    let UsedBytes: UInt64?
}

struct XTopDiskMount: Codable, Identifiable {
    var id: String { Mountpoint }
    let Mountpoint: String
    let Fstype: String
    let Total: UInt64
    let Used: UInt64
    let Free: UInt64
    let UsedPercent: Double
    let ReadPerSec: Double
    let WritePerSec: Double
}

struct XTopNet: Codable {
    let UploadPerSec: Double
    let DownloadPerSec: Double
    let TotalUpload: UInt64
    let TotalDownload: UInt64
    let TopProcs: [XTopNetProc]?
    let ProcsSupported: Bool?
}

struct XTopNetProc: Codable, Identifiable {
    var id: String { "\(PID)-\(Command)" }
    let PID: Int32
    let Command: String
    let UploadPerSec: Double
    let DownloadPerSec: Double
}

struct XTopGPU: Codable {
    let Available: Bool
    let Message: String?
    let Cards: [XTopGPUCard]?
    let TopProcs: [XTopGPUProc]?
    let ProcsSupported: Bool?
}

struct XTopGPUCard: Codable, Identifiable {
    var id: String { Name }
    let Name: String
    let PowerW: Double
    let MemUsed: UInt64
    let MemTotal: UInt64
    let TempC: Double
    let LoadPct: Double
}

struct XTopGPUProc: Codable, Identifiable {
    var id: String { "\(PID)-\(Command)" }
    let PID: Int32
    let Command: String
    let MemBytes: UInt64
}

struct XTopProc: Codable {
    let Total: Int
    let TopCPU: [XTopProcInfo]?
    let TopMem: [XTopProcInfo]?
    let TopDisk: [XTopProcInfo]?

    enum CodingKeys: String, CodingKey {
        case Total = "total"
        case TopCPU = "top_cpu"
        case TopMem = "top_mem"
        case TopDisk = "top_disk"
    }
}

struct XTopProcInfo: Codable, Identifiable {
    var id: String { "\(PID)-\(Command)" }
    let PID: Int32
    let User: String?
    let Status: String?
    let CPU: Double
    let MemRSS: UInt64
    let Command: String
}

// MARK: - 格式化辅助

extension UInt64 {
    /// 将字节格式化为人类可读字符串（B/KiB/MiB/GiB/TiB）。
    func formattedBytes() -> String {
        let f = Double(self)
        if self >= (1 << 40) { return String(format: "%.2f TiB", f / Double(1 << 40)) }
        if self >= (1 << 30) { return String(format: "%.2f GiB", f / Double(1 << 30)) }
        if self >= (1 << 20) { return String(format: "%.2f MiB", f / Double(1 << 20)) }
        if self >= (1 << 10) { return String(format: "%.2f KiB", f / Double(1 << 10)) }
        return "\(self) B"
    }
}

extension Double {
    /// 将字节/秒格式化为人类可读字符串。
    func formattedBytesPerSecond() -> String {
        guard self >= 0 else { return "N/A" }
        if self >= Double(1 << 40) { return String(format: "%.2f TiB/s", self / Double(1 << 40)) }
        if self >= Double(1 << 30) { return String(format: "%.2f GiB/s", self / Double(1 << 30)) }
        if self >= Double(1 << 20) { return String(format: "%.2f MiB/s", self / Double(1 << 20)) }
        if self >= Double(1 << 10) { return String(format: "%.2f KiB/s", self / Double(1 << 10)) }
        return String(format: "%.1f B/s", self)
    }

    /// 将百分比格式化为字符串。
    func formattedPercent() -> String {
        guard self >= 0 else { return "N/A" }
        return String(format: "%.1f%%", self)
    }

    /// 将温度格式化为字符串。
    func formattedCelsius() -> String {
        guard self >= 0 else { return "N/A" }
        return String(format: "%.1f°C", self)
    }

    /// 将功率格式化为字符串。
    func formattedWatts() -> String {
        guard self >= 0 else { return "N/A" }
        return String(format: "%.1f W", self)
    }
}
