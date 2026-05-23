# Launchpad

An interactive Bash script that installs and configures a complete DevOps + networking toolchain on Ubuntu in one shot — with a live progress bar, per-operation timers, idempotent installs, and a full `--uninstall` mode that reverses everything.

---

## Requirements

| Requirement | Detail |
|---|---|
| **OS** | Ubuntu 20.04 / 22.04 / 24.04 |
| **Architecture** | `amd64` (x86_64) or `arm64` (aarch64) |
| **Privileges** | `sudo` access (no need to run as root) |
| **Internet** | Required — tools are fetched from official sources |

---

## Quick Start

```bash
git clone https://github.com/siyamsarker/launchpad.git
cd launchpad
chmod +x launchpad.sh
./launchpad.sh
```

A checklist menu opens. Toggle tools with `SPACE`, confirm with `ENTER`.

---

## Global Install

Copy Launchpad to `/usr/local/bin` so you can call it from any directory:

```bash
./launchpad.sh --install-self
```

After that:

```bash
launchpad             # open the interactive installer
launchpad --help      # show all flags
```

To remove it from your PATH later:

```bash
launchpad --uninstall-self
```

---

## Managed Tools

### DevOps & Infrastructure

| Tool | What it does | Install source |
|---|---|---|
| `osupdate` | System packages update & full upgrade | apt |
| `kubectl` | Kubernetes CLI | Kubernetes apt repo |
| `eksctl` | Amazon EKS cluster CLI | GitHub binary |
| `awscli` | AWS CLI v2 | Amazon official installer |
| `terraform` | Infrastructure as Code | HashiCorp apt repo |
| `helm` | Kubernetes package manager | Official get-helm-3 script |
| `docker` | Container runtime + Compose v2 | get.docker.com script |
| `k9s` | Terminal dashboard for Kubernetes | GitHub binary |
| `ansible` | Configuration management | Ansible PPA |

### Utilities

| Tool | What it does | Install source |
|---|---|---|
| `jq` | JSON processor | Ubuntu apt |
| `yq` | YAML processor | GitHub binary |
| `fzf` | Fuzzy finder | Ubuntu apt |
| `bat` | Syntax-highlighted `cat` replacement | Ubuntu apt |
| `nano` | Terminal text editor | Ubuntu apt |
| `duf` | Disk usage / free utility | GitHub `.deb` |

### Network & Troubleshooting

| Tool | What it does | Install source |
|---|---|---|
| `nmap` | Network scanner & port discovery | Ubuntu apt |
| `mtr` | Network diagnostic — ping + traceroute combined | Ubuntu apt |
| `tcpdump` | Packet capture & traffic analysis | Ubuntu apt |
| `iperf3` | Network bandwidth & performance testing | Ubuntu apt |
| `dnsutils` | DNS tools — `dig`, `nslookup`, `host` | Ubuntu apt |
| `netcat` | TCP/UDP swiss army knife (`nc`) | Ubuntu apt |

All tools are fetched from their official, vendor-provided sources. No third-party mirrors.

---

## Usage

```bash
launchpad                   # interactive install (tool checklist)
launchpad --status          # show installed / missing status for all tools
launchpad --uninstall       # remove all managed tools
launchpad --install-self    # copy launchpad to /usr/local/bin
launchpad --uninstall-self  # remove launchpad from /usr/local/bin
launchpad --help            # show all flags
```

### Flags

| Flag | Alias | Description |
|---|---|---|
| *(none)* | | Interactive mode — select tools and install |
| `--status` | `-s` | Show installed / missing status of all tools |
| `--uninstall` | `-u` | Remove all managed tools |
| `--install-self` | | Copy `launchpad` to `/usr/local/bin` |
| `--uninstall-self` | | Remove `launchpad` from `/usr/local/bin` |
| `--help` | `-h` | Show usage message |

---

## What You See While It Runs

**Tool section header** — shows current position in the queue:
```
  ────────────────────────────────────────────────────────
  [3/8]  terraform      Infrastructure as Code
  ────────────────────────────────────────────────────────
```

**Live spinner with elapsed time** — updates every ~80 ms:
```
    ⠼  Adding HashiCorp apt repo…  [14s]
```

**Progress bar after each tool** — fills as tools complete, with ETA:
```
  [████████████░░░░░░░░░░░░░░░░░░░░]  3/8  (37%)  Elapsed: 1m 5s  ETA: ~1m 50s
```

**Summary with per-tool timing** — shown at the end:
```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Installation Summary  (total: 3m 22s)
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Installed (6):
    ✔  kubectl          23s
    ✔  eksctl           8s
    ✔  terraform        1m 23s
    ✔  docker           1m 15s
    ✔  helm             12s
    ✔  k9s              7s
```

**Tool status check** — `launchpad --status`:
```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Tool Status  21 managed tools  •  2026-05-23 14:00
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✔  kubectl          v1.30.2
  ✔  docker           26.1.3
  ✖  nmap             not installed  →  run: launchpad

  ✔  Installed: 14   ✖  Missing: 7   Total: 21
```

---

## Logs

Every run writes a timestamped log to `/tmp/`:

```
/tmp/launchpad-20260523-141500.log
```

If any tool fails, the log path is printed in the inline error and in the final summary.

---

## Idempotency

Each tool checks whether it is already installed before doing any work. Running the script a second time skips already-present tools and reports them under **"Already present / skipped"** in the summary. No duplicate installs, no broken state.

---

## Uninstall

```bash
launchpad --uninstall
```

- Prompts for `YES` confirmation before removing anything.
- Docker has an additional confirmation prompt because removing it also wipes `/var/lib/docker` (all images, containers, and volumes).
- `osupdate` is intentionally skipped during uninstall — OS upgrades are not reversible.
- Each tool is only removed if it is detected on the system — never fails on tools that were never installed.

---

## Extending

To add a new tool, define two functions in `launchpad.sh`:

```bash
install_mytool() {
  log_step "mytool"
  if command -v mytool &>/dev/null; then
    log_warn "mytool already installed. Skipping."
    SKIPPED+=("mytool"); return
  fi
  quietly "Installing mytool…" sudo apt-get install -y -qq mytool
  log_ok "$(mytool --version)"
  INSTALLED+=("mytool")
}

uninstall_mytool() {
  log_step "Removing mytool"
  sudo apt-get remove -y -qq mytool >>"$LOG_FILE" 2>&1 || true
  log_ok "mytool removed"
}
```

Then register it in two places near the top of the file:

```bash
ALL_TOOLS=(... mytool)

TOOL_DESC=(
  ...
  [mytool]="Short description shown in the checklist"
)
```

If the installed binary name differs from the tool id (e.g. `dnsutils` → `dig`), add a case to `_tool_installed()` and `_tool_version()` in the STATUS CHECK section.

The progress tracking, timing, and interactive selector pick everything up automatically.

---

## Notes

- **Docker group**: after Docker is installed, the script adds your user to the `docker` group. You must **log out and back in** for this to take effect.
- **sudo keepalive**: a background process refreshes your `sudo` ticket every 55 seconds so it never expires mid-install on long runs.
- **Arch detection**: all binary downloads automatically select `amd64` or `arm64` based on `uname -m`.
- **osupdate**: always runs as the first step when selected. The uninstall mode skips it intentionally — OS upgrades cannot be rolled back.
