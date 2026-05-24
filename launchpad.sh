#!/usr/bin/env bash
# =============================================================================
# Launchpad — DevOps Workspace Installer
# Compatible : Ubuntu 20.04 / 22.04 / 24.04 (amd64 & arm64)
# Usage      : ./launchpad.sh [--uninstall | --install-self | --help]
#
# Tools managed:
#   kubectl · eksctl · awscli · terraform · helm · docker · k9s · ansible
#   jq · yq · fzf · bat · nano · vim · duf
#   nmap · mtr · tcpdump · dnsutils · netcat · net-tools
#   psql · atlascli · mongosh · redis-cli
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Colors & styles ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Global state ─────────────────────────────────────────────────────────────
LOG_FILE="/tmp/launchpad-$(date +%Y%m%d-%H%M%S).log"
declare -a INSTALLED=()
declare -a FAILED=()
declare -a SKIPPED=()
declare -a SELECTED_TOOLS=()
SUDO_KEEPALIVE_PID=""

# ── Progress tracking ─────────────────────────────────────────────────────────
declare -A TOOL_TIMES=()   # tool → seconds taken
INSTALL_TOTAL=0            # set in run_install before the loop
INSTALL_CURRENT=0          # incremented by _tool_header
INSTALL_START=0            # epoch at first tool start
TOOL_START=0               # epoch at current tool start

# ── Tool registry ─────────────────────────────────────────────────────────────
declare -A TOOL_DESC=(
  [osupdate]="System packages update & full upgrade (apt)"
  [kubectl]="Kubernetes CLI"
  [eksctl]="Amazon EKS CLI"
  [awscli]="AWS CLI v2"
  [terraform]="Infrastructure as Code"
  [helm]="Kubernetes Package Manager"
  [docker]="Container Runtime + Compose v2"
  [k9s]="Kubernetes Terminal Dashboard"
  [jq]="JSON Processor"
  [yq]="YAML Processor"
  [fzf]="Fuzzy Finder"
  [bat]="Syntax-highlighted cat replacement"
  [ansible]="Configuration Management"
  [nano]="Terminal Text Editor"
  [vim]="Vi IMproved — Advanced Text Editor"
  [duf]="Disk Usage / Free Utility"
  # Network tools
  [nmap]="Network Scanner & Port Discovery"
  [mtr]="Network diagnostic (ping + traceroute)"
  [tcpdump]="Packet Capture & Traffic Analysis"
  [dnsutils]="DNS tools: dig, nslookup, host"
  [netcat]="TCP/UDP Swiss Army Knife (nc)"
  [nettools]="net-tools: ifconfig, netstat, route, arp"
  # Database tools
  [psql]="PostgreSQL Client"
  [atlascli]="MongoDB Atlas CLI"
  [mongosh]="MongoDB Shell"
  [rediscli]="Redis CLI"
)
ALL_TOOLS=(osupdate kubectl eksctl awscli terraform helm docker k9s jq yq fzf bat ansible nano vim duf nmap mtr tcpdump dnsutils netcat nettools psql atlascli mongosh rediscli)

# ── apt helper — suppresses needrestart and debconf prompts ──────────────────
apt_install() {
  sudo bash -c 'DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq "$@"' _ "$@"
}

# ── Logging ───────────────────────────────────────────────────────────────────
_log()      { echo -e "$*" | tee -a "$LOG_FILE"; }
log_info()  { _log "${CYAN}  ➜${NC}  $*"; }
log_ok()    { _log "${GREEN}  ✔${NC}  $*"; }
log_warn()  { _log "${YELLOW}  ⚠${NC}  $*"; }
log_error() { _log "${RED}  ✖${NC}  $*"; }
log_step()  { (( INSTALL_TOTAL > 0 )) && return; _log "\n${BOLD}${BLUE}▶ $*${NC}"; }
log_dim()   { _log "${DIM}    $*${NC}"; }

# ── Spinner ───────────────────────────────────────────────────────────────────
_spin() {
  local pid=$1 msg=$2
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0 t0 elapsed
  t0=$(date +%s)
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - t0 ))
    printf "\r    ${CYAN}%s${NC}  %s  ${DIM}[%ds]${NC}   " \
      "${frames[$((i % 10))]}" "$msg" "$elapsed"
    i=$(( i + 1 ))
    sleep 0.08
  done
  tput cnorm 2>/dev/null || true
  printf "\r\033[K"
}

# Run a command silently with a spinner; exits non-zero on failure.
quietly() {
  local msg="$1"; shift
  "$@" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  _spin "$pid" "$msg"
  wait "$pid"
}

# ── Helpers ───────────────────────────────────────────────────────────────────
arch() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *)       echo "$m"    ;;
  esac
}

gh_latest() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | grep '"tag_name"' | cut -d'"' -f4
}

# ── Progress UI helpers ───────────────────────────────────────────────────────

# Human-readable duration: 0-59s → "42s", ≥60s → "1m 5s"
_fmt_time() {
  local s=$1
  (( s < 60 )) && printf "%ds" "$s" || printf "%dm %ds" "$(( s / 60 ))" "$(( s % 60 ))"
}

_divider() {
  printf "${DIM}  %-56s${NC}\n" "──────────────────────────────────────────────────────"
}

# Print the overall progress bar. Call with (current total).
_print_progress_bar() {
  local current=$1 total=$2
  local width=32 filled pct elapsed eta_str=""
  filled=$(( current * width / total ))
  pct=$(( current * 100 / total ))
  elapsed=$(( $(date +%s) - INSTALL_START ))

  local bar="" i
  for (( i = 0; i < filled; i++ ));       do bar+="█"; done
  for (( i = filled; i < width; i++ ));   do bar+="░"; done

  if (( current > 0 && elapsed > 0 )); then
    local avg=$(( elapsed / current ))
    local remain=$(( (total - current) * avg ))
    eta_str="  ${DIM}ETA ~$(_fmt_time "$remain")${NC}"
  fi

  echo ""
  _divider
  printf "  ${BOLD}[%s]${NC}  ${CYAN}%d/%d${NC}  ${DIM}(%d%%)${NC}  Elapsed: ${BOLD}%s${NC}%b\n" \
    "$bar" "$current" "$total" "$pct" "$(_fmt_time "$elapsed")" "$eta_str"
  _divider
  echo ""
}

# Print the section header for a tool. Increments INSTALL_CURRENT.
_tool_header() {
  local tool=$1
  INSTALL_CURRENT=$(( INSTALL_CURRENT + 1 ))
  TOOL_START=$(date +%s)
  echo ""
  _divider
  printf "  ${BOLD}${BLUE}[%d/%d]${NC}  ${BOLD}%-12s${NC}  ${DIM}%s${NC}\n" \
    "$INSTALL_CURRENT" "$INSTALL_TOTAL" "$tool" "${TOOL_DESC[$tool]:-}"
  _divider
}

# Print timing + updated progress bar after a tool completes.
# Usage: _tool_done <toolname> <ok|skip|fail>
_tool_done() {
  local tool=$1 status=$2
  local elapsed=$(( $(date +%s) - TOOL_START ))
  TOOL_TIMES[$tool]=$elapsed

  case "$status" in
    ok)   printf "  ${DIM}  ⏱  Completed in %s${NC}\n" "$(_fmt_time "$elapsed")" ;;
    skip) : ;;
    fail) printf "  ${DIM}  ⏱  Failed after %s${NC}\n"    "$(_fmt_time "$elapsed")" ;;
  esac
  _print_progress_bar "$INSTALL_CURRENT" "$INSTALL_TOTAL"
}

# ── Banner ────────────────────────────────────────────────────────────────────
banner() {
  clear
  printf "${BOLD}${BLUE}"
  cat <<'BANNER'

  ██╗      █████╗ ██╗   ██╗███╗   ██╗ ██████╗██╗  ██╗██████╗  █████╗ ██████╗
  ██║     ██╔══██╗██║   ██║████╗  ██║██╔════╝██║  ██║██╔══██╗██╔══██╗██╔══██╗
  ██║     ███████║██║   ██║██╔██╗ ██║██║     ███████║██████╔╝███████║██║  ██║
  ██║     ██╔══██║██║   ██║██║╚██╗██║██║     ██╔══██║██╔═══╝ ██╔══██║██║  ██║
  ███████╗██║  ██║╚██████╔╝██║ ╚████║╚██████╗██║  ██║██║     ██║  ██║██████╔╝
  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚═════╝

BANNER
  printf "${NC}"
  printf "${DIM}  Launchpad — DevOps Workspace Installer  •  Ubuntu 20.04 / 22.04 / 24.04\n"
  printf "  Log → %s${NC}\n\n" "$LOG_FILE"
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
  log_step "Checking prerequisites"

  if [[ ! -f /etc/os-release ]] || ! grep -qi ubuntu /etc/os-release; then
    log_error "This script targets Ubuntu. Detected: $(uname -s)"
    exit 1
  fi
  local ver; ver=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
  log_ok "Ubuntu $ver detected"

  if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    log_info "Requesting sudo access…"
    sudo -v || { log_error "sudo required. Exiting."; exit 1; }
  fi

  ( while true; do sudo -n true; sleep 55; done ) 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap '_cleanup' EXIT INT TERM

  # apt-transport-https and lsb-release are built-in / transitional on Ubuntu 22.04+
  local deps=(curl wget ca-certificates gnupg unzip)
  log_info "Refreshing package index…"
  sudo apt-get update -qq >>"$LOG_FILE" 2>&1 \
    || log_warn "Package index refresh had errors — continuing (see $LOG_FILE)"

  # Repair any packages left half-configured by a previously interrupted install
  sudo bash -c 'DEBIAN_FRONTEND=noninteractive dpkg --configure -a' >>"$LOG_FILE" 2>&1 || true
  sudo bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq' >>"$LOG_FILE" 2>&1 || true

  for dep in "${deps[@]}"; do
    if ! dpkg -s "$dep" &>/dev/null; then
      quietly "Installing $dep…" apt_install "$dep" \
        || log_warn "Could not install $dep — continuing"
    fi
  done
  log_ok "Prerequisites satisfied"
}

_cleanup() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

install_osupdate() {
  log_step "OS Update & Upgrade"
  quietly "Refreshing package lists…" \
    sudo apt-get update -q
  quietly "Upgrading installed packages…" \
    sudo bash -c 'DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q'
  quietly "Removing unused packages…" \
    sudo bash -c 'DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q && apt-get autoclean -q'
  log_ok "System is up to date"
  INSTALLED+=("osupdate")
}

uninstall_osupdate() {
  # OS upgrades cannot be reversed — this is intentionally a no-op.
  log_warn "OS updates are not reversible and will not be undone."
}

# ─────────────────────────────────────────────────────────────────────────────

install_kubectl() {
  log_step "kubectl"
  if command -v kubectl &>/dev/null; then
    log_warn "kubectl already installed — $(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}'). Skipping."
    SKIPPED+=("kubectl"); return
  fi
  quietly "Adding Kubernetes apt repo…" sudo bash -c '
    KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
      | gpg --dearmor -o "$KEYRING"
    echo "deb [signed-by=${KEYRING}] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    apt-get install -y -qq kubectl
  '
  log_ok "kubectl $(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}')"
  INSTALLED+=("kubectl")
}

uninstall_kubectl() {
  log_step "Removing kubectl"
  sudo apt-get remove -y -qq kubectl >>"$LOG_FILE" 2>&1 || true
  sudo rm -f /etc/apt/sources.list.d/kubernetes.list \
             /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  log_ok "kubectl removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_eksctl() {
  log_step "eksctl"
  if command -v eksctl &>/dev/null; then
    log_warn "eksctl already installed — $(eksctl version). Skipping."
    SKIPPED+=("eksctl"); return
  fi
  quietly "Downloading eksctl…" sudo bash -c "
    ARCH=\"\$(uname -m)\"
    [[ \"\$ARCH\" == \"x86_64\" ]] && ARCH=\"amd64\" || ARCH=\"arm64\"
    curl -fsSL \"https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_\${ARCH}.tar.gz\" \
      | tar xz -C /tmp eksctl
    mv /tmp/eksctl /usr/local/bin/eksctl
    chmod +x /usr/local/bin/eksctl
  "
  log_ok "eksctl $(eksctl version)"
  INSTALLED+=("eksctl")
}

uninstall_eksctl() {
  log_step "Removing eksctl"
  sudo rm -f /usr/local/bin/eksctl
  log_ok "eksctl removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_awscli() {
  log_step "AWS CLI v2"
  if command -v aws &>/dev/null; then
    log_warn "AWS CLI already installed — $(aws --version). Skipping."
    SKIPPED+=("awscli"); return
  fi
  quietly "Downloading AWS CLI v2…" sudo bash -c "
    ARCH=\"\$(uname -m)\"
    curl -fsSL \"https://awscli.amazonaws.com/awscli-exe-linux-\${ARCH}.zip\" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp/awscli-extract
    /tmp/awscli-extract/aws/install --update
    rm -rf /tmp/awscliv2.zip /tmp/awscli-extract
  "
  log_ok "$(aws --version)"
  INSTALLED+=("awscli")
}

uninstall_awscli() {
  log_step "Removing AWS CLI v2"
  sudo rm -rf /usr/local/aws-cli
  sudo rm -f  /usr/local/bin/aws /usr/local/bin/aws_completer
  log_ok "AWS CLI v2 removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_terraform() {
  log_step "Terraform"
  if command -v terraform &>/dev/null; then
    log_warn "Terraform already installed — $(terraform version -json | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4). Skipping."
    SKIPPED+=("terraform"); return
  fi
  quietly "Adding HashiCorp apt repo…" sudo bash -c '
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
      https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | tee /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq
    apt-get install -y -qq terraform
  '
  log_ok "$(terraform version | head -1)"
  INSTALLED+=("terraform")
}

uninstall_terraform() {
  log_step "Removing Terraform"
  sudo apt-get remove -y -qq terraform >>"$LOG_FILE" 2>&1 || true
  sudo rm -f /etc/apt/sources.list.d/hashicorp.list \
             /usr/share/keyrings/hashicorp-archive-keyring.gpg
  log_ok "Terraform removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_helm() {
  log_step "Helm"
  if command -v helm &>/dev/null; then
    log_warn "Helm already installed — $(helm version --short). Skipping."
    SKIPPED+=("helm"); return
  fi
  quietly "Installing Helm via official installer…" bash -c \
    'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
  log_ok "$(helm version --short)"
  INSTALLED+=("helm")
}

uninstall_helm() {
  log_step "Removing Helm"
  sudo rm -f /usr/local/bin/helm
  log_ok "Helm removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_docker() {
  log_step "Docker + Docker Compose v2"
  if command -v docker &>/dev/null; then
    log_warn "Docker already installed — $(docker --version). Skipping."
    SKIPPED+=("docker"); return
  fi
  quietly "Installing Docker via official installer…" sudo bash -c '
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  '
  local real_user="${SUDO_USER:-$USER}"
  if [[ -n "$real_user" && "$real_user" != "root" ]]; then
    sudo usermod -aG docker "$real_user"
    log_warn "Added '$real_user' to the docker group — log out and back in for it to take effect."
  fi
  log_ok "$(docker --version)"
  log_ok "$(docker compose version)"
  INSTALLED+=("docker")
}

uninstall_docker() {
  log_step "Removing Docker"
  log_warn "This will also delete /var/lib/docker (all images, containers, volumes)."
  read -rp "  Type YES to confirm Docker data removal: " confirm
  [[ "$confirm" != "YES" ]] && { log_warn "Skipping Docker removal."; return; }
  sudo systemctl stop docker docker.socket 2>/dev/null || true
  sudo apt-get remove -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >>"$LOG_FILE" 2>&1 || true
  sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
  sudo rm -f  /etc/apt/sources.list.d/docker.list \
              /etc/apt/keyrings/docker.gpg
  log_ok "Docker removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_k9s() {
  log_step "k9s"
  if command -v k9s &>/dev/null; then
    log_warn "k9s already installed — $(k9s version --short 2>/dev/null). Skipping."
    SKIPPED+=("k9s"); return
  fi
  quietly "Downloading k9s…" sudo bash -c "
    ARCH=\"\$(uname -m)\"
    [[ \"\$ARCH\" == \"x86_64\" ]] && ARCH=\"amd64\" || ARCH=\"arm64\"
    TAG=\$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest \
          | grep '\"tag_name\"' | cut -d'\"' -f4)
    curl -fsSL \"https://github.com/derailed/k9s/releases/download/\${TAG}/k9s_Linux_\${ARCH}.tar.gz\" \
      | tar xz -C /tmp k9s
    mv /tmp/k9s /usr/local/bin/k9s
    chmod +x /usr/local/bin/k9s
  "
  log_ok "$(k9s version --short 2>/dev/null)"
  INSTALLED+=("k9s")
}

uninstall_k9s() {
  log_step "Removing k9s"
  sudo rm -f /usr/local/bin/k9s
  log_ok "k9s removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_jq() {
  log_step "jq"
  if command -v jq &>/dev/null; then
    log_warn "jq already installed — $(jq --version). Skipping."
    SKIPPED+=("jq"); return
  fi
  quietly "Installing jq…" apt_install jq
  log_ok "$(jq --version)"
  INSTALLED+=("jq")
}

uninstall_jq() {
  log_step "Removing jq"
  sudo apt-get remove -y -qq jq >>"$LOG_FILE" 2>&1 || true
  log_ok "jq removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_yq() {
  log_step "yq"
  if command -v yq &>/dev/null; then
    log_warn "yq already installed — $(yq --version). Skipping."
    SKIPPED+=("yq"); return
  fi
  quietly "Downloading yq…" sudo bash -c "
    ARCH=\"\$(uname -m)\"
    [[ \"\$ARCH\" == \"x86_64\" ]] && ARCH=\"amd64\" || ARCH=\"arm64\"
    curl -fsSL \"https://github.com/mikefarah/yq/releases/latest/download/yq_linux_\${ARCH}\" \
      -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
  "
  log_ok "$(yq --version)"
  INSTALLED+=("yq")
}

uninstall_yq() {
  log_step "Removing yq"
  sudo rm -f /usr/local/bin/yq
  log_ok "yq removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_fzf() {
  log_step "fzf"
  if command -v fzf &>/dev/null; then
    log_warn "fzf already installed — $(fzf --version). Skipping."
    SKIPPED+=("fzf"); return
  fi
  quietly "Installing fzf…" apt_install fzf
  log_ok "fzf $(fzf --version)"
  INSTALLED+=("fzf")
}

uninstall_fzf() {
  log_step "Removing fzf"
  sudo apt-get remove -y -qq fzf >>"$LOG_FILE" 2>&1 || true
  log_ok "fzf removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_bat() {
  log_step "bat"
  if command -v bat &>/dev/null || command -v batcat &>/dev/null; then
    log_warn "bat already installed. Skipping."
    SKIPPED+=("bat"); return
  fi
  quietly "Installing bat…" apt_install bat
  if ! command -v bat &>/dev/null && command -v batcat &>/dev/null; then
    sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
    log_dim "Symlinked batcat → /usr/local/bin/bat"
  fi
  log_ok "bat $(bat --version 2>/dev/null || batcat --version)"
  INSTALLED+=("bat")
}

uninstall_bat() {
  log_step "Removing bat"
  sudo apt-get remove -y -qq bat >>"$LOG_FILE" 2>&1 || true
  sudo rm -f /usr/local/bin/bat
  log_ok "bat removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_ansible() {
  log_step "Ansible"
  if command -v ansible &>/dev/null; then
    log_warn "Ansible already installed — $(ansible --version | head -1). Skipping."
    SKIPPED+=("ansible"); return
  fi
  quietly "Adding Ansible PPA and installing…" sudo bash -c '
    add-apt-repository -y ppa:ansible/ansible >/dev/null 2>&1
    apt-get update -qq
    apt-get install -y -qq ansible
  '
  log_ok "$(ansible --version | head -1)"
  INSTALLED+=("ansible")
}

uninstall_ansible() {
  log_step "Removing Ansible"
  sudo apt-get remove -y -qq ansible >>"$LOG_FILE" 2>&1 || true
  sudo add-apt-repository -y --remove ppa:ansible/ansible >>"$LOG_FILE" 2>&1 || true
  log_ok "Ansible removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_nano() {
  log_step "nano"
  if command -v nano &>/dev/null; then
    log_warn "nano already installed — $(nano --version | head -1). Skipping."
    SKIPPED+=("nano"); return
  fi
  quietly "Installing nano…" apt_install nano
  log_ok "$(nano --version | head -1)"
  INSTALLED+=("nano")
}

uninstall_nano() {
  log_step "Removing nano"
  sudo apt-get remove -y -qq nano >>"$LOG_FILE" 2>&1 || true
  log_ok "nano removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_vim() {
  log_step "vim"
  if command -v vim &>/dev/null; then
    log_warn "vim already installed. Skipping."
    SKIPPED+=("vim"); return
  fi
  quietly "Installing vim…" apt_install vim
  if ! command -v vim &>/dev/null; then
    log_error "vim binary not found after install — check $LOG_FILE"
    return 1
  fi
  log_ok "$(vim --version 2>/dev/null | head -1)"
  INSTALLED+=("vim")
}

uninstall_vim() {
  log_step "Removing vim"
  sudo apt-get remove -y -qq vim >>"$LOG_FILE" 2>&1 || true
  log_ok "vim removed"
}

# ─────────────────────────────────────────────────────────────────────────────

install_duf() {
  log_step "duf"
  if command -v duf &>/dev/null; then
    log_warn "duf already installed — $(duf --version 2>/dev/null). Skipping."
    SKIPPED+=("duf"); return
  fi
  quietly "Downloading duf…" sudo bash -c "
    ARCH=\"\$(uname -m)\"
    [[ \"\$ARCH\" == \"x86_64\" ]] && DEB_ARCH=\"amd64\" || DEB_ARCH=\"arm64\"
    TAG=\$(curl -fsSL https://api.github.com/repos/muesli/duf/releases/latest \
          | grep '\"tag_name\"' | cut -d'\"' -f4)
    VER=\${TAG#v}
    curl -fsSL \"https://github.com/muesli/duf/releases/download/\${TAG}/duf_\${VER}_linux_\${DEB_ARCH}.deb\" \
      -o /tmp/duf.deb
    dpkg -i /tmp/duf.deb
    rm -f /tmp/duf.deb
  "
  log_ok "$(duf --version 2>/dev/null)"
  INSTALLED+=("duf")
}

uninstall_duf() {
  log_step "Removing duf"
  sudo dpkg -r duf >>"$LOG_FILE" 2>&1 || true
  log_ok "duf removed"
}

# =============================================================================
# NETWORK TOOLS
# =============================================================================

install_nmap() {
  log_step "nmap"
  if command -v nmap &>/dev/null; then
    log_warn "nmap already installed. Skipping."
    SKIPPED+=("nmap"); return
  fi
  quietly "Installing nmap…" apt_install nmap
  log_ok "$(nmap --version 2>/dev/null | head -1)"
  INSTALLED+=("nmap")
}

uninstall_nmap() {
  log_step "Removing nmap"
  sudo apt-get remove -y -qq nmap >>"$LOG_FILE" 2>&1 || true
  log_ok "nmap removed"
}

install_mtr() {
  log_step "mtr"
  if command -v mtr &>/dev/null; then
    log_warn "mtr already installed. Skipping."
    SKIPPED+=("mtr"); return
  fi
  quietly "Installing mtr…" apt_install mtr-tiny
  log_ok "$(mtr --version 2>/dev/null | head -1)"
  INSTALLED+=("mtr")
}

uninstall_mtr() {
  log_step "Removing mtr"
  sudo apt-get remove -y -qq mtr-tiny >>"$LOG_FILE" 2>&1 || true
  log_ok "mtr removed"
}

install_tcpdump() {
  log_step "tcpdump"
  if command -v tcpdump &>/dev/null; then
    log_warn "tcpdump already installed. Skipping."
    SKIPPED+=("tcpdump"); return
  fi
  quietly "Installing tcpdump…" apt_install tcpdump
  log_ok "$(tcpdump --version 2>&1 | head -1)"
  INSTALLED+=("tcpdump")
}

uninstall_tcpdump() {
  log_step "Removing tcpdump"
  sudo apt-get remove -y -qq tcpdump >>"$LOG_FILE" 2>&1 || true
  log_ok "tcpdump removed"
}


install_dnsutils() {
  log_step "dnsutils"
  if command -v dig &>/dev/null; then
    log_warn "dnsutils already installed. Skipping."
    SKIPPED+=("dnsutils"); return
  fi
  quietly "Installing dnsutils…" apt_install dnsutils
  log_ok "$(dig -v 2>&1 | head -1)"
  INSTALLED+=("dnsutils")
}

uninstall_dnsutils() {
  log_step "Removing dnsutils"
  sudo apt-get remove -y -qq dnsutils >>"$LOG_FILE" 2>&1 || true
  log_ok "dnsutils removed"
}

install_netcat() {
  log_step "netcat"
  if command -v nc &>/dev/null; then
    log_warn "netcat already installed. Skipping."
    SKIPPED+=("netcat"); return
  fi
  quietly "Installing netcat-openbsd…" apt_install netcat-openbsd
  log_ok "netcat (openbsd) installed"
  INSTALLED+=("netcat")
}

uninstall_netcat() {
  log_step "Removing netcat"
  sudo apt-get remove -y -qq netcat-openbsd >>"$LOG_FILE" 2>&1 || true
  log_ok "netcat removed"
}

install_nettools() {
  log_step "net-tools"
  if command -v ifconfig &>/dev/null; then
    log_warn "net-tools already installed. Skipping."
    SKIPPED+=("nettools"); return
  fi
  quietly "Installing net-tools…" apt_install net-tools
  if ! command -v ifconfig &>/dev/null; then
    log_error "net-tools binary not found after install — check $LOG_FILE"
    return 1
  fi
  log_ok "net-tools (ifconfig, netstat, route, arp)"
  INSTALLED+=("nettools")
}

uninstall_nettools() {
  log_step "Removing net-tools"
  sudo apt-get remove -y -qq net-tools >>"$LOG_FILE" 2>&1 || true
  log_ok "net-tools removed"
}

# =============================================================================
# DATABASE TOOLS
# =============================================================================

install_psql() {
  log_step "psql"
  if command -v psql &>/dev/null; then
    log_warn "psql already installed — $(psql --version 2>/dev/null). Skipping."
    SKIPPED+=("psql"); return
  fi
  quietly "Installing postgresql-client…" apt_install postgresql-client
  if ! command -v psql &>/dev/null; then
    log_error "psql binary not found after install — check $LOG_FILE"
    return 1
  fi
  log_ok "$(psql --version)"
  INSTALLED+=("psql")
}

uninstall_psql() {
  log_step "Removing psql"
  sudo apt-get remove -y -qq postgresql-client >>"$LOG_FILE" 2>&1 || true
  log_ok "psql removed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Atlas CLI and mongosh share a MongoDB apt repo keyring. Each install sets it
# up idempotently; each uninstall only removes the repo files if neither binary
# remains on the system after removal.
# ─────────────────────────────────────────────────────────────────────────────

install_atlascli() {
  log_step "Atlas CLI"
  if command -v atlas &>/dev/null; then
    log_warn "Atlas CLI already installed. Skipping."
    SKIPPED+=("atlascli"); return
  fi
  quietly "Adding MongoDB apt repo and installing Atlas CLI…" sudo bash -c '
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    mongo_ver="7.0"
    [[ "$codename" == "noble" ]] && mongo_ver="8.0"
    case "$codename" in focal|jammy|noble) ;; *) codename="jammy" ;; esac
    curl -fsSL "https://pgp.mongodb.com/server-${mongo_ver}.asc" \
      | gpg --dearmor -o /usr/share/keyrings/mongodb-server.gpg
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server.gpg ] \
      https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/${mongo_ver} multiverse" \
      > /etc/apt/sources.list.d/mongodb-org.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq mongodb-atlas
  '
  if ! command -v atlas &>/dev/null; then
    log_error "atlas binary not found after install — check $LOG_FILE"
    return 1
  fi
  log_ok "$(atlas --version 2>/dev/null | head -1)"
  INSTALLED+=("atlascli")
}

uninstall_atlascli() {
  log_step "Removing Atlas CLI"
  sudo apt-get remove -y -qq mongodb-atlas >>"$LOG_FILE" 2>&1 || true
  if ! command -v mongosh &>/dev/null; then
    sudo rm -f /etc/apt/sources.list.d/mongodb-org.list \
               /usr/share/keyrings/mongodb-server.gpg
  fi
  log_ok "Atlas CLI removed"
}

install_mongosh() {
  log_step "mongosh"
  if command -v mongosh &>/dev/null; then
    log_warn "mongosh already installed. Skipping."
    SKIPPED+=("mongosh"); return
  fi
  quietly "Adding MongoDB apt repo and installing mongosh…" sudo bash -c '
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
    mongo_ver="7.0"
    [[ "$codename" == "noble" ]] && mongo_ver="8.0"
    case "$codename" in focal|jammy|noble) ;; *) codename="jammy" ;; esac
    if [[ ! -f /usr/share/keyrings/mongodb-server.gpg ]]; then
      curl -fsSL "https://pgp.mongodb.com/server-${mongo_ver}.asc" \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server.gpg
    fi
    if [[ ! -f /etc/apt/sources.list.d/mongodb-org.list ]]; then
      echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server.gpg ] \
        https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/${mongo_ver} multiverse" \
        > /etc/apt/sources.list.d/mongodb-org.list
      apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq mongodb-mongosh
  '
  if ! command -v mongosh &>/dev/null; then
    log_error "mongosh binary not found after install — check $LOG_FILE"
    return 1
  fi
  log_ok "$(mongosh --version 2>/dev/null)"
  INSTALLED+=("mongosh")
}

uninstall_mongosh() {
  log_step "Removing mongosh"
  sudo apt-get remove -y -qq mongodb-mongosh >>"$LOG_FILE" 2>&1 || true
  if ! command -v atlas &>/dev/null; then
    sudo rm -f /etc/apt/sources.list.d/mongodb-org.list \
               /usr/share/keyrings/mongodb-server.gpg
  fi
  log_ok "mongosh removed"
}

install_rediscli() {
  log_step "redis-cli"
  if command -v redis-cli &>/dev/null; then
    log_warn "redis-cli already installed. Skipping."
    SKIPPED+=("rediscli"); return
  fi
  quietly "Installing redis-tools…" apt_install redis-tools
  if ! command -v redis-cli &>/dev/null; then
    log_error "redis-cli binary not found after install — check $LOG_FILE"
    return 1
  fi
  log_ok "$(redis-cli --version 2>/dev/null)"
  INSTALLED+=("rediscli")
}

uninstall_rediscli() {
  log_step "Removing redis-cli"
  sudo apt-get remove -y -qq redis-tools >>"$LOG_FILE" 2>&1 || true
  log_ok "redis-cli removed"
}

# =============================================================================
# INTERACTIVE TOOL SELECTOR
# =============================================================================

select_tools() {
  if command -v whiptail &>/dev/null; then
    _select_whiptail
  else
    _select_fallback
  fi
}

_select_whiptail() {
  local items=()
  for tool in "${ALL_TOOLS[@]}"; do
    items+=("$tool" "${TOOL_DESC[$tool]}" "ON")
  done

  local n=${#ALL_TOOLS[@]}
  local term_h; term_h=$(tput lines 2>/dev/null || echo 40)
  local term_w; term_w=$(tput cols  2>/dev/null || echo 80)

  # Width = widest "[*] TAG   DESCRIPTION" line + dialog chrome (6)
  local max_item=0
  for tool in "${ALL_TOOLS[@]}"; do
    local w=$(( 4 + ${#tool} + 3 + ${#TOOL_DESC[$tool]} ))
    (( w > max_item )) && max_item=$w
  done
  local dlg_w=$(( max_item + 6 ))
  (( dlg_w < 60 ))          && dlg_w=60
  (( dlg_w > term_w - 4 ))  && dlg_w=$(( term_w - 4 ))

  local dlg_h=$(( n + 9 ))
  (( dlg_h > term_h - 2 )) && dlg_h=$(( term_h - 2 ))
  local list_h=$(( dlg_h - 9 ))
  (( list_h < 5 )) && list_h=5

  local raw
  raw=$(whiptail --title " Launchpad — DevOps Workspace Installer " \
    --checklist "\nSPACE = toggle  |  ENTER = confirm  |  TAB = switch buttons\n" \
    "$dlg_h" "$dlg_w" "$list_h" "${items[@]}" \
    3>&1 1>&2 2>&3) || { echo -e "\n${YELLOW}  Cancelled.${NC}"; exit 0; }
  IFS=' ' read -r -a SELECTED_TOOLS <<< "${raw//\"/}"
}

_select_fallback() {
  echo -e "\n${BOLD}  Available tools:${NC}\n"
  local i=1
  for tool in "${ALL_TOOLS[@]}"; do
    printf "  ${CYAN}%2d)${NC} %-12s  %s\n" "$i" "$tool" "${TOOL_DESC[$tool]}"
    (( i++ )) || true
  done
  echo -e "\n  ${DIM}Enter numbers, ranges (e.g. 1-5), or 'all'${NC}"
  read -rp "  Selection: " raw
  SELECTED_TOOLS=()
  if [[ "$raw" == "all" ]]; then
    SELECTED_TOOLS=("${ALL_TOOLS[@]}"); return
  fi
  for token in $raw; do
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      for (( n=BASH_REMATCH[1]; n<=BASH_REMATCH[2]; n++ )); do
        (( n >= 1 && n <= ${#ALL_TOOLS[@]} )) && SELECTED_TOOLS+=("${ALL_TOOLS[$((n-1))]}")
      done
    elif [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#ALL_TOOLS[@]} )); then
      SELECTED_TOOLS+=("${ALL_TOOLS[$((token-1))]}")
    fi
  done
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
  local hbar="${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  local total_elapsed=$(( $(date +%s) - INSTALL_START ))
  echo -e "\n$hbar"
  printf "${BOLD}  Installation Summary${NC}  ${DIM}(total: %s)${NC}\n" \
    "$(_fmt_time "$total_elapsed")"
  echo -e "$hbar"

  if (( ${#INSTALLED[@]} > 0 )); then
    echo -e "\n${GREEN}  Installed (${#INSTALLED[@]}):${NC}"
    for t in "${INSTALLED[@]}"; do
      printf "    ${GREEN}✔${NC}  %-14s  ${DIM}%s${NC}\n" "$t" "$(_fmt_time "${TOOL_TIMES[$t]:-0}")"
    done
  fi
  if (( ${#SKIPPED[@]} > 0 )); then
    echo -e "\n${YELLOW}  Already present / skipped (${#SKIPPED[@]}):${NC}"
    for t in "${SKIPPED[@]}"; do
      printf "    ${YELLOW}–${NC}  %-14s  ${DIM}already installed${NC}\n" "$t"
    done
  fi
  if (( ${#FAILED[@]} > 0 )); then
    echo -e "\n${RED}  Failed (${#FAILED[@]}):${NC}"
    for t in "${FAILED[@]}"; do
      printf "    ${RED}✖${NC}  %-14s  ${DIM}%s${NC}\n" "$t" "$(_fmt_time "${TOOL_TIMES[$t]:-0}")"
    done
    echo -e "\n${DIM}  Inspect the log: ${LOG_FILE}${NC}"
  fi

  echo -e "\n${DIM}  Full log → ${LOG_FILE}${NC}"
  echo -e "$hbar\n"
}

# =============================================================================
# STATUS CHECK
# =============================================================================

# Returns 0 if the tool binary/package is present on the system.
_tool_installed() {
  case "$1" in
    osupdate)  return 0 ;;  # the OS itself is always present
    awscli)    command -v aws &>/dev/null || [[ -f /usr/local/bin/aws ]] ;;
    bat)       command -v bat &>/dev/null || command -v batcat &>/dev/null ;;
    dnsutils)  command -v dig &>/dev/null ;;
    netcat)    command -v nc &>/dev/null || command -v ncat &>/dev/null ;;
    nettools)  command -v ifconfig &>/dev/null ;;
    atlascli)  command -v atlas &>/dev/null ;;
    rediscli)  command -v redis-cli &>/dev/null ;;
    *)         command -v "$1" &>/dev/null ;;
  esac
}

# Prints a short version string for an installed tool.
_tool_version() {
  case "$1" in
    osupdate)  lsb_release -ds 2>/dev/null || uname -sr ;;
    kubectl)   kubectl version --client 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 ;;
    eksctl)    eksctl version 2>/dev/null ;;
    awscli)    aws --version 2>&1 | awk '{print $1}' ;;
    terraform) terraform version 2>/dev/null | head -1 ;;
    helm)      helm version --short 2>/dev/null ;;
    docker)    docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' ;;
    k9s)       k9s version --short 2>/dev/null | grep -o 'v[0-9][0-9.]*' ;;
    jq)        jq --version 2>/dev/null ;;
    yq)        yq --version 2>/dev/null | awk '{print $NF}' ;;
    fzf)       fzf --version 2>/dev/null | awk '{print $1}' ;;
    bat)       { bat --version 2>/dev/null || batcat --version 2>/dev/null; } | awk '{print $2}' ;;
    ansible)   ansible --version 2>/dev/null | head -1 ;;
    nano)      nano --version 2>/dev/null | head -1 | awk '{print $NF}' ;;
    duf)       duf --version 2>/dev/null | awk '{print $2}' ;;
    nmap)      nmap --version 2>/dev/null | head -1 | awk '{print $3}' ;;
    mtr)       mtr --version 2>/dev/null | awk '{print $2}' ;;
    tcpdump)   tcpdump --version 2>&1 | head -1 | awk '{print $3}' ;;
    dnsutils)  dig -v 2>&1 | awk '{print $2}' ;;
    netcat)    dpkg -s netcat-openbsd 2>/dev/null | grep 'Version:' | awk '{print $2}' ;;
    vim)       vim --version 2>/dev/null | head -1 | awk '{print $5}' ;;
    nettools)  dpkg -s net-tools 2>/dev/null | grep 'Version:' | awk '{print $2}' ;;
    psql)      psql --version 2>/dev/null | awk '{print $3}' ;;
    atlascli)  atlas --version 2>/dev/null | head -1 ;;
    mongosh)   mongosh --version 2>/dev/null ;;
    rediscli)  redis-cli --version 2>/dev/null | awk '{print $3}' ;;
  esac
}

run_status() {
  local hbar="${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  local installed=0 missing=0

  echo ""
  echo -e "$hbar"
  printf "${BOLD}  Tool Status${NC}  ${DIM}%d managed tools  •  %s${NC}\n" \
    "${#ALL_TOOLS[@]}" "$(date '+%Y-%m-%d %H:%M')"
  echo -e "$hbar"
  echo ""

  for tool in "${ALL_TOOLS[@]}"; do
    if _tool_installed "$tool"; then
      local ver; ver=$(_tool_version "$tool" 2>/dev/null | head -1 | xargs)
      printf "  ${GREEN}✔${NC}  ${BOLD}%-14s${NC}  ${DIM}%s${NC}\n" "$tool" "${ver:-installed}"
      installed=$(( installed + 1 ))
    else
      printf "  ${RED}✖${NC}  ${BOLD}%-14s${NC}  ${DIM}not installed${NC}  ${YELLOW}→  run: launchpad${NC}\n" "$tool"
      missing=$(( missing + 1 ))
    fi
  done

  echo ""
  echo -e "$hbar"
  printf "  ${GREEN}✔  Installed: %d${NC}   ${RED}✖  Missing: %d${NC}   ${DIM}Total: %d${NC}\n" \
    "$installed" "$missing" "${#ALL_TOOLS[@]}"
  echo -e "$hbar"
  echo ""

  if (( missing > 0 )); then
    printf "  ${YELLOW}Install %d missing tool(s) now?${NC}  ${DIM}[y/N]${NC}  " "$missing"
    read -r _status_ans
    if [[ "${_status_ans,,}" == "y" ]]; then
      SELECTED_TOOLS=()
      for tool in "${ALL_TOOLS[@]}"; do
        _tool_installed "$tool" || SELECTED_TOOLS+=("$tool")
      done
      echo ""
      check_prerequisites
      _exec_install
    fi
  fi
}

# =============================================================================
# MODES
# =============================================================================

_exec_install() {
  INSTALL_TOTAL=${#SELECTED_TOOLS[@]}
  INSTALL_CURRENT=0
  INSTALL_START=$(date +%s)

  echo ""
  printf "  ${BOLD}Starting installation of %d tool(s)…${NC}\n" "$INSTALL_TOTAL"
  _print_progress_bar 0 "$INSTALL_TOTAL"

  for tool in "${SELECTED_TOOLS[@]}"; do
    if ! declare -f "install_${tool}" &>/dev/null; then
      log_warn "Unknown tool: '$tool' — skipping"; continue
    fi

    _tool_header "$tool"

    local result="ok"
    if ! "install_${tool}" 2>>"$LOG_FILE"; then
      log_error "  $tool installation failed — see $LOG_FILE"
      FAILED+=("$tool")
    fi

    if [[ " ${SKIPPED[*]:-} " =~ " $tool " ]]; then
      result="skip"
    elif [[ " ${FAILED[*]:-} " =~ " $tool " ]]; then
      result="fail"
    fi

    _tool_done "$tool" "$result"
  done

  print_summary
}

run_install() {
  banner
  select_tools

  if (( ${#SELECTED_TOOLS[@]} == 0 )); then
    log_warn "No tools selected. Exiting."
    exit 0
  fi

  # Resolve which selected tools actually need installation
  local to_install=()
  for tool in "${SELECTED_TOOLS[@]}"; do
    _tool_installed "$tool" || to_install+=("$tool")
  done

  if (( ${#to_install[@]} == 0 )); then
    echo ""
    log_ok "All selected tools are already installed."
    printf "  ${DIM}Run ${BOLD}launchpad --status${DIM} to view installed versions.${NC}\n\n"
    exit 0
  fi

  SELECTED_TOOLS=("${to_install[@]}")
  check_prerequisites
  _exec_install
}

run_uninstall() {
  banner
  echo -e "${RED}${BOLD}  UNINSTALL MODE${NC}"
  echo -e "  This will remove all DevOps tools managed by this script.\n"
  read -rp "  Type YES to confirm: " confirm
  [[ "$confirm" != "YES" ]] && { echo -e "\n${YELLOW}  Aborted.${NC}\n"; exit 0; }
  echo ""

  for tool in "${ALL_TOOLS[@]}"; do
    # OS upgrades are not reversible — skip silently in uninstall mode
    if [[ "$tool" == "osupdate" ]]; then
      log_dim "osupdate — system upgrades are not reversible, skipping"
      continue
    fi

    local present=false
    local cmd="$tool"
    [[ "$tool" == "awscli" ]] && cmd="aws"
    command -v "$cmd" &>/dev/null && present=true
    [[ "$tool" == "awscli" && -f /usr/local/bin/aws ]] && present=true

    if $present; then
      "uninstall_${tool}" 2>>"$LOG_FILE" || log_warn "$tool removal encountered errors (see log)"
    else
      log_dim "$tool not found — skipping"
    fi
  done

  echo ""
  log_ok "Uninstall complete. Log → $LOG_FILE"
}

# =============================================================================
# SELF INSTALL / UNINSTALL
# =============================================================================

# Copy this script to /usr/local/bin/launchpad so it is available system-wide.
install_self() {
  local target="/usr/local/bin/launchpad"
  local src; src=$(realpath "$0")

  if [[ "$src" == "$target" ]]; then
    log_warn "Already running from $target — nothing to do."
    return
  fi

  log_info "Copying to $target…"
  sudo cp "$src" "$target"
  sudo chmod +x "$target"
  log_ok "Installed! Run ${BOLD}launchpad${NC} from anywhere."
  log_dim "To remove: launchpad --uninstall-self"
}

# Remove the script from /usr/local/bin.
uninstall_self() {
  local target="/usr/local/bin/launchpad"
  if [[ -f "$target" ]]; then
    sudo rm -f "$target"
    log_ok "Removed $target — 'launchpad' command is no longer in PATH."
  else
    log_warn "'launchpad' not found at $target — nothing to remove."
  fi
}

# =============================================================================
# USAGE / ENTRY POINT
# =============================================================================

usage() {
  local name; name=$(basename "$0")

  echo -e "\n${BOLD}Usage:${NC}  ${BOLD}${CYAN}$name${NC} [OPTIONS]\n"

  # ── Options ────────────────────────────────────────────────────────────────
  echo -e "${BOLD}Options${NC}"
  printf "  ${CYAN}%-22s${NC}  %s\n" "(no flags)"       "Launch the interactive tool installer"
  printf "  ${CYAN}%-22s${NC}  %s\n" "--status"         "Show installed / missing status of all tools"
  printf "  ${CYAN}%-22s${NC}  %s\n" "--uninstall"      "Remove all managed DevOps tools"
  printf "  ${CYAN}%-22s${NC}  %s\n" "--install-self"   "Copy launchpad to /usr/local/bin (run from anywhere)"
  printf "  ${CYAN}%-22s${NC}  %s\n" "--uninstall-self" "Remove launchpad from /usr/local/bin"
  printf "  ${CYAN}%-22s${NC}  %s\n" "--help"           "Show this message"

  # ── Examples ───────────────────────────────────────────────────────────────
  echo -e "\n${BOLD}Examples${NC}"
  printf "  ${DIM}\$${NC} ${BOLD}%-38s${NC} ${DIM}# %s${NC}\n" \
    "./$name"                 "open the interactive installer"
  printf "  ${DIM}\$${NC} ${BOLD}%-38s${NC} ${DIM}# %s${NC}\n" \
    "./$name --install-self"  "make 'launchpad' available system-wide"
  printf "  ${DIM}\$${NC} ${BOLD}%-38s${NC} ${DIM}# %s${NC}\n" \
    "launchpad --status"      "check which tools are installed"
  printf "  ${DIM}\$${NC} ${BOLD}%-38s${NC} ${DIM}# %s${NC}\n" \
    "launchpad"               "run from anywhere after install-self"
  printf "  ${DIM}\$${NC} ${BOLD}%-38s${NC} ${DIM}# %s${NC}\n" \
    "launchpad --uninstall"   "remove all managed tools"

  # ── Managed tools (in columns) ─────────────────────────────────────────────
  echo -e "\n${BOLD}Managed tools${NC}  ${DIM}(${#ALL_TOOLS[@]})${NC}"
  local i=0 cols=5
  for tool in "${ALL_TOOLS[@]}"; do
    printf "  ${GREEN}%-14s${NC}" "$tool"
    i=$(( i + 1 ))
    if [[ $(( i % cols )) -eq 0 ]]; then printf "\n"; fi
  done
  if [[ $(( i % cols )) -ne 0 ]]; then printf "\n"; fi

  printf "\n${DIM}  Log → /tmp/launchpad-<YYYYmmdd-HHMMSS>.log${NC}\n\n"
}

main() {
  case "${1:-}" in
    --status|-s)      run_status     ;;
    --uninstall|-u)   run_uninstall  ;;
    --install-self)   install_self   ;;
    --uninstall-self) uninstall_self ;;
    --help|-h)        usage          ;;
    "")               run_install    ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
}

main "$@"
