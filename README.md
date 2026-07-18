<!-- LOGO -->
<h1>
<p align="center">
  <img src="images/newicon/icon_1024.png" alt="ExGhostty" width="160">
  <br>ExGhostty
</h1>
<p align="center">
  <b>A brand-new SSH tool based on Ghostty.</b>
</p>
<p align="center">
   <b>English</b> · <a href="README_zh.md">简体中文</a>
</p>

---

## Why ExGhostty?

ExGhostty was born out of a genuine love for [Ghostty](https://ghostty.org) —
a fast, native, beautiful terminal emulator. But as much as we love Ghostty,
it was never designed to be a traditional **SSH tool**:

- **Ghostty doesn't fit the SSH-tool workflow.** Managing many remote hosts,
  jumping between them, transferring files, and keeping port forwards alive are
  things a plain terminal emulator simply doesn't help you with.
- **Ghostty's configuration is intimidating.** Everything is done by editing a
  text configuration file, which is a real barrier for newcomers who just want
  to connect to a server and get work done.
- **Terminals are falling behind the AI era.** With the rise of large language
  models, a traditional terminal that only echoes text can no longer keep up
  with how people actually want to work.

ExGhostty is **not** an attempt to build a bloated, do-everything tool. It
focuses on doing **SSH really well**, adds a small set of commonly needed
capabilities around it, and keeps a close, practical integration with **AI
 models**.

It is **free and open source** — no subscriptions, no ads, ever. The goal is
simply to offer another option, so that people who love Ghostty have one more
choice that fits the way they work.

---

## Features

### Core: SSH made easy
- **SSH connection manager** — organize hosts in groups, with password or
  key-based authentication, jump-host (bastion) support, per-host encoding,
  timeouts and keep-alive.
- **One-click connect** — double-click a host to open a session. Passwords are
  stored **AES-encrypted**, never in plain text.
- **Connection testing** — verify reachability and authentication before saving.
- **Local terminal** — a full Ghostty terminal is always one click away.

### SFTP file manager
- Browse remote directories alongside the terminal (follows `cd` in the shell).
- Upload / download files and folders with **rsync**, with **resume support**
  for unstable networks.
- Task window with per-task progress, pause / resume / cancel, and error
  details you can copy.

### Port forwarding
- Create **local (-L)**, **remote (-R)** and **dynamic (-D)** forwards.
- Start / stop with one click, automatic keep-alive and restart.
- Port-conflict detection with an option to kill the occupying process.

### Session reuse
- Attach to existing **tmux** and **zellij** sessions, create new ones, or
  detach — on both local and remote hosts.

### Code snippets
- Save frequently used shell / Python snippets in groups.
- Run a snippet in the current terminal with a double-click.

### System monitor
- Live CPU / memory / disk / network / GPU cards for local and remote hosts,
  powered by [xtop](https://github.com/rarnu/xtop).

### AI assistant
- Chat with an LLM (OpenAI-compatible endpoint) with your **current terminal
  context** (directory, SSH host, title) included automatically.
- Commands and scripts in replies are shown in runnable blocks — copy them into
  the terminal with one click.

### And more
- **Settings window** — configure everything through a native GUI (no hand
  editing of config files), including themes with previews and keybindings.
- **iCloud sync** — synchronize configuration, SSH hosts, port-forward rules
  and code snippets across your Macs via iCloud Drive.
- Built on the fast, native **Ghostty** terminal engine.

---

## Requirements

- macOS
- [Zig](https://ziglang.org) **0.15.2**
- Xcode (for building the macOS app)

## Build

```bash
./release.sh
```

The release app bundle is produced at `zig-out/ExGhostty.app`.

## Usage

1. Launch **ExGhostty**.
2. Use the **left sidebar** to create and manage SSH connections and local
   terminals.
3. Use the **right sidebar** to open the tools: SFTP, port forwarding, session
   reuse, system monitor, code snippets, and the AI assistant.
4. Open **Settings** to adjust appearance, themes, keybindings, sync and
   language — no config file editing required.

---

## License

ExGhostty is free and open source. See the repository for license details.