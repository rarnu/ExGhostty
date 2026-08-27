//
//  Translations.session.swift
//  ExGhostty_iPad
//
//  English translations for the session area (see Translations.swift):
//  Features/Session, Features/Keys and the SFTP panel (including the
//  Chinese error messages produced by SFTPViewModel, which are wrapped
//  with L() at the display sites in SFTPPanelView).
//

import Foundation

extension Translations {
    static let session: [String: String] = [
        // MARK: Session（标签页 / 功能栏 / 空态引导）
        "正在连接 %@:%d…": "Connecting to %@:%d…",
        "连接失败": "Connection Failed",
        "连接已中断": "Connection lost",
        "连接已断开，正在重连…": "Connection lost. Reconnecting…",
        "已重新连接": "Reconnected",
        "重连失败": "Reconnect failed",
        "按任意键重新连接…": "Press any key to reconnect…",
        "终端": "Terminal",
        "端口": "Ports",
        "监控": "Monitor",
        "SSH 终端": "SSH Terminal",
        "SFTP 文件管理": "SFTP File Manager",
        "Session 复用": "Session Reuse",
        "端口占用": "Port Usage",
        "Docker 管理": "Docker",
        "系统监控": "System Monitor",
        "功能完整的 SSH 客户端\n支持密钥认证、跳板机与连接分组":
            "A full-featured SSH client\nwith key authentication, jump hosts, and connection groups",
        "从左侧栏选择或新增一个 SSH 连接开始":
            "Select or add an SSH connection in the sidebar to get started",

        // MARK: Keys（密钥管理）
        "没有 SSH 密钥": "No SSH Keys",
        "点击 + 导入密钥文件，或直接粘贴密钥文本":
            "Tap + to import a key file, or paste the key text directly",
        "从文件导入": "Import from File",
        "粘贴文本": "Paste Text",
        "命名密钥": "Name Key",
        "密钥名称": "Key Name",
        "导入": "Import",
        "取消": "Cancel",
        "为这把密钥起一个便于识别的名称": "Give this key a name you can recognize",
        "导入失败": "Import Failed",
        "好": "OK",
        "删除": "Delete",
        "名称": "Name",
        "密钥文本": "Key Text",
        "粘贴以 -----BEGIN 开头的私钥内容，支持未加密的 OpenSSH 和 PEM 格式。":
            "Paste the private key starting with -----BEGIN. Unencrypted OpenSSH and PEM formats are supported.",
        "粘贴密钥": "Paste Key",
        "无法读取文件内容，请选择文本格式的私钥文件":
            "Could not read the file. Please choose a text-format private key file.",

        // MARK: SFTP 面板
        "新建文件夹": "New Folder",
        "文件夹名称": "Folder Name",
        "创建": "Create",
        "重命名": "Rename",
        "新名称": "New Name",
        "确定": "OK",
        "确定删除目录 “%@” 及其全部内容吗？": "Delete the directory \"%@\" and all of its contents?",
        "确定删除文件 “%@” 吗？": "Delete the file \"%@\"?",
        "错误": "Error",
        "%@ 未安装": "%@ is not installed",
        "安装": "Install",
        "远端机器未安装 %@。":
            "%@ is not installed on the remote machine.",
        "正在打开 SFTP 会话…": "Opening SFTP session…",
        "SFTP 打开失败": "Failed to Open SFTP",
        "远端找不到 sftp-server，无法以切换后的用户身份运行 SFTP":
            "sftp-server not found on the remote host; cannot run SFTP as the switched user",
        "切换用户失败：sudo 密码错误或未配置 NOPASSWD":
            "Failed to switch user: wrong sudo password or NOPASSWD not configured",
        "重试": "Retry",
        "上级目录": "Parent Directory",
        "刷新": "Refresh",
        "显示/隐藏隐藏文件": "Show/Hide Hidden Files",
        "上传文件": "Upload File",
        "上传目录": "Upload Folder",
        "空目录": "Empty Directory",
        "下载": "Download",
        "下载目录": "Download Folder",
        "使用 %@ 打开目录": "Open Directory with %@",
        "使用 %@ 打开": "Open with %@",
        "未知": "Unknown",
        "终端不可用": "Terminal unavailable",

        // MARK: SFTPViewModel 的中文错误消息（Panel 显示处 L() 包裹）
        "rm -rf 失败": "rm -rf failed",
        "远程打包失败": "Remote packing failed",
        "远程解压失败": "Remote extraction failed",
    ]
}
