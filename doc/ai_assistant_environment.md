# AI 助手环境上下文增强

## 背景

ExGhostty 内置 AI 助手（OpenAI 兼容接口）最初只把当前目录发给模型，
上下文贫瘠导致两类问题：

1. **OS 语义错误**：用户环境是 macOS，但询问命令参数时 AI 按 Linux
   标准（GNU 工具、/proc 等）回答，结论在 mac 上不可用。
2. **运维辅助弱**：上下文里没有系统资源数据，AI 无法回答
   "内存为什么高"、"哪个进程吃 CPU"这类运维问题，也难以给出
   基于实际环境的命令建议。

## 方案

### 1. EnvironmentCollector 探测脚本（macOS/Sources/Features/AIAssistant/EnvironmentCollector.swift）

在对应环境（本地 / SSH 远程）执行一段 POSIX 探测脚本，结果拼进 system prompt：

| 段 | 内容 | 来源 |
|----|------|------|
| T1 OS 身份 | `OS:`（uname）、`OS family`（macOS/Linux/其他）、`macOS version`（sw_vers）、CPU 架构（Apple Silicon/Intel）、Brew 版本、`Shell:`、`Hostname:`、Linux 发行版（/etc/os-release） | shell 内置命令 |
| T2 资源快照 | `xtop --all --json` **原始 JSON 直传，不做任何解析**（cpu/mem/disk/gpu/net/proc 全量字段）；未安装 xtop 则整段跳过 | xtop 命令 |
| T3 Git | 当前分支、origin 地址、clean/dirty 状态（仅 git 仓库内） | git |
| T4 工具 | python3/node/go/java/rustc/docker/kubectl/npm/git 版本（仅已安装的输出） | `command -v` + `--version` |
| T5 环境变量 | VIRTUAL_ENV / CONDA_DEFAULT_ENV / GOPATH / JAVA_HOME / NVM_DIR / Conda 环境列表 | shell 环境 |

### 2. system prompt 规则（macOS/Sources/Features/AIAssistant/AIAssistantService.swift `makeSystemPrompt`）

```
- The "OS family" line is authoritative. If it says macOS, answer all
  command/parameter/behavior questions with macOS semantics (zsh, BSD
  awk/sed/grep, sysctl, launchctl, Homebrew, no /proc); if it says Linux,
  use the Linux defaults. Never mix the two.
- When explaining a command's parameters or behavior, describe how that
  command behaves on the OS stated in the context; only mention
  differences on other OSes briefly.
- Resource numbers ... are a point-in-time sample; treat them as
  reference values, not live measurements.
- When suggesting commands, prefer tools the context says are installed.
```

原有的 ```command / ```python 围栏代码块约定保留（面板依赖它识别可执行内容）。

## 关键设计决策

1. **xtop JSON 直传，不解析**（用户明确要求）。理由：
   - xtop 是本项目系统监控面板的同一数据源，字段语义已对齐；
   - 解析（awk/jq）要处理所有字段的转义与版本漂移，脆弱且无收益——
     LLM 读 JSON 的能力远强于 shell 脚本；
   - 体积（本机实测 ~40KB，主要 gpu.TopProcs/proc 明细）由 5 分钟 TTL
     缓存摊薄，不会每次请求重复采集。
2. **只保留 xtop 覆盖不到的采集**：OS 身份（uname/sw_vers）、Git、
   工具版本、环境变量。CPU/内存/磁盘/网络/负载/进程全部交给 xtop，
   不再手写 free/df/netstat/sysctl 分支。
3. **OS family 显式标注**：`OS: Darwin ...` 之外额外输出
   `OS family: macOS`，配合 system prompt 的权威声明双重保险。
4. **防挂起**：xtop 不带 `--stream`（单次输出即退出）；
   整个脚本包裹在 `( ... ) || true` 子 shell + 末尾 `exit 0`，
   因为 `ProcessRunner.run(shellCommand:)` 在退出码非 0 时会丢弃 stdout 抛异常。
5. **防思考块污染**：`stripThinkBlocks` 剥离远端 AI shell 插件
   （如通义灵码）混入的 think 标签块。标签用字符串拼接构造字面量，
   避免被代码处理工具误转义。

## 缓存

- key：本地固定 `local`，远程 `ssh-<connection.id>`
- TTL：300 秒；过期后下次发消息时重新采集
- 静态字典 + 惰性清理，无锁（调用方在 MainActor 上）

## 测试

- `macOS/Tests/AIAssistant/EnvironmentCollectorTests.swift`
  - 探测脚本不变量：子 shell 包裹、exit 0 守卫、括号配平
  - OS 身份 / Git / 工具 / 环境变量采集存在性
  - xtop 段：`--all --json` 存在、`--stream` 不存在、
    段内无 awk/jq（保证 JSON 直传）
  - stripThinkBlocks：无块/单块/未闭合/空块/首尾空白
- `macOS/Tests/AIAssistant/AIAssistantServiceTests.swift`
  - 上下文原样嵌入
  - OS family 权威规则、快照参考规则、优先已装工具
  - 代码块格式约定保留
  - 空上下文兜底

## 验证方式

```sh
# 模拟 Swift 运行时（多行字符串 \\ -> \ 解码）后实际执行
python3 -c "
import re
src = open('macos/Sources/Features/AIAssistant/EnvironmentCollector.swift').read()
s = src.index('probeScript = \"\"\"')
b = src[s+17:]; b = b[:b.rindex('\"\"\"')]
open('/tmp/p.sh','w').write(b.replace('\\\\\\\\','\\\\'))
"
zsh /tmp/p.sh   # exit 0；macOS 上应看到 OS family: macOS + xtop JSON
```

实测输出（M5 Max / macOS 27）：

```
OS: Darwin 27.0.0 arm64
OS family: macOS
macOS version: 26.5
CPU arch: Apple Silicon (arm64)
Brew: Homebrew 6.0.18
Shell: /bin/zsh
Hostname: Rarnus-M5MAX.local
{ "time": ..., "cpu": {...}, "mem": {...}, "disk": {...}, "gpu": {...}, "net": {...}, "proc": {...} }
Git branch: main
...
```