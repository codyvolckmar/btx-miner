#!/usr/bin/env bash
# btx-miner-menu — control panel for the nekominer BTXv4 miner.
# Interactive (whiptail) or headless (--status/--start/--stop/--restart/--install/--preflight).
set -uo pipefail

APP_TITLE="BTX MINER"
VERSION="v0.21.0"
DIR="${BTX_MINER_DIR:-/opt/btx}"
CONF="$DIR/miner.conf"
PIDFILE="$DIR/supervisor.pid"
LOGFILE="$DIR/miner.log"
SUPOUT="$DIR/supervisor.out"
SUPERVISOR="$DIR/supervisor.sh"
BIN="$DIR/nekominer"
URL="https://github.com/nr800/nekominer/releases/download/$VERSION/nekominer"
SHA="4d2a59b32bea2ea867992ab3d81c7e746a2c7f2cb273d311033d3acf7819088f"

# ---------- defaults (overridden by miner.conf) ----------
POOLS="btx.ninjaraider.com:44950,btx-pool.com:3334"   # ninjaraider = 0% dev fee
WALLET="${BTX_WALLET:-}"   # btx1...ADDRESS.WORKER - set via Settings, miner.conf, or BTX_WALLET
ALGO="btxv4"
FAILBACK="120"
EXTRA=""
DEVICES=""   # GPUs to mine on, e.g. "0,1,3" - blank = all GPUs

mkdir -p "$DIR" 2>/dev/null || { echo "Cannot create $DIR (try running as root or set BTX_MINER_DIR)" >&2; exit 1; }
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
save_conf() {
  {
    echo "# nekominer config — edit via the menu, or directly here"
    printf 'POOLS=%q\nWALLET=%q\nALGO=%q\nFAILBACK=%q\nEXTRA=%q\nDEVICES=%q\n' \
      "$POOLS" "$WALLET" "$ALGO" "$FAILBACK" "$EXTRA" "$DEVICES"
  } > "$CONF"
}
[ -f "$CONF" ] || save_conf

# ---------- helpers ----------
strip_ansi() { sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g'; }   # -u: unbuffered, for tail -f
# nekominer prints a stats table every few seconds:
#   | GPU | Bus ID | Name | Util | Temp | Fan | Core | Mem | mV | Hashrate | Accepted | Rejected |
# These read the GPU rows of the most recent table.
miner_table() {   # "totals" -> "accepted rejected hashing/gpus hashrate" ; "rows" -> one line per GPU
  tail -n 300 "$LOGFILE" 2>/dev/null | strip_ansi | awk -F'|' -v mode="$1" '
    function t(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /Accepted/ { n = a = r = h = live = 0; unit = ""; next }
    /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {
      split(t($(NF-3)), hr, " "); h += hr[1]; if (unit == "") unit = hr[2]; if (hr[1] + 0 > 0) live++
      a += $(NF-2); r += $(NF-1)
      row[++n] = sprintf("GPU%-2s %-20s %12s  %4s  util %4s  acc %s rej %s",
                         t($2), t($4), t($(NF-3)), t($6), t($5), t($(NF-2)), t($(NF-1))) \
               (hr[1] + 0 > 0 ? "" : "  <-- NOT HASHING")
    }
    END {
      if (mode == "rows") { for (i = 1; i <= n; i++) print row[i] }
      else printf "%d %d %d/%d %s\n", a, r, live, n, (n ? sprintf("%.2f %s", h, unit) : "n/a")
    }'
}
log_events() {    # recent log lines minus the stats tables and their header line
  tail -n 400 "$LOGFILE" 2>/dev/null | strip_ansi \
    | grep -v -E '^[+|]|^[0-9:]+ nekominer \|' | tail -n "$1" | cut -c1-$(( BOX_W - 8 )) | grep . \
    || echo "  (none)"
}
size_h()     { [ -s "$1" ] && du -h "$1" | cut -f1 || echo empty; }

pretty_time() {
  local t=${1:-0} d h m
  d=$((t/86400)); h=$((t%86400/3600)); m=$((t%3600/60))
  (( d )) && { printf '%dd%dh' "$d" "$h"; return; }
  (( h )) && { printf '%dh%dm' "$h" "$m"; return; }
  printf '%dm%ds' "$m" "$((t%60))"
}

last_error() {
  [ -f "$LOGFILE" ] || return 0
  tail -n 60 "$LOGFILE" | strip_ansi | grep -i -E 'error|fail|cannot|denied|refused|mismatch' | tail -n 1 | cut -c1-90
}

BOX_H=22 BOX_W=78
box_fit() {   # fit dialogs to the terminal so whiptail never says "box too small"
  local l c
  l=$(tput lines 2>/dev/null || echo 24); c=$(tput cols 2>/dev/null || echo 80)
  BOX_H=$(( l - 4 )); (( BOX_H < 8 )) && BOX_H=8; (( BOX_H > 26 )) && BOX_H=26
  BOX_W=$(( c - 4 )); (( BOX_W < 40 )) && BOX_W=40; (( BOX_W > 100 )) && BOX_W=100
}
msg()   { box_fit; whiptail --title "$APP_TITLE" --backtitle "$DIR" --msgbox "$1" "$BOX_H" "$BOX_W"; }
err()   { box_fit; whiptail --title "$APP_TITLE — ERROR" --backtitle "$DIR" --msgbox "$1" "$BOX_H" "$BOX_W"; }
ask()   {   # inputbox sized to its prompt (the GPU picker lists up to 8 cards)
  local h; h=$(( $(printf '%b\n' "$1" | wc -l) + 8 )); box_fit; (( h > BOX_H )) && h=$BOX_H
  whiptail --title "$APP_TITLE" --backtitle "Settings" --inputbox "$1" "$h" 74 "$2" 3>&1 1>&2 2>&3
}
yesno() { whiptail --title "$APP_TITLE" --backtitle "$DIR" --yesno "$1" 14 72; }

# ---------- environment preflight ----------
# nekominer is a CUDA miner: it needs the NVIDIA driver (NVML) or it dies at startup.
nvml_present() { ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so.1 /usr/lib/libnvidia-ml.so.1 2>/dev/null | head -n1; }
gpu_names() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    # "8x NVIDIA GeForce RTX 3090" (mixed rigs: "4x ..., 2x ...")
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort | uniq -c \
      | awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "%s%dx %s", (NR > 1 ? ", " : ""), c, $0 } END { print "" }'
  else
    local g; g=$(lspci 2>/dev/null | grep -i -E 'vga|3d controller' | sed 's/.*: //' | paste -sd';' -)
    echo "${g:-none detected}"
  fi
}
gpu_count() { nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true; }
gpu_line()  { echo "$(gpu_count) detected, mining on: ${DEVICES:-all}"; }
# preflight [quiet]: returns 0 if OK; otherwise prints/dialogs the problems and returns 1
preflight() {
  local problems=()
  [ -x "$BIN" ] || problems+=("nekominer binary not installed")
  [ -n "$(nvml_present)" ] || problems+=("libnvidia-ml.so.1 missing (no NVIDIA driver)")
  command -v nvidia-smi >/dev/null 2>&1 || problems+=("nvidia-smi missing")
  [[ "$WALLET" == btx1* ]] || problems+=("wallet not set (Settings > Wallet, or BTX_WALLET=btx1...WORKER)")
  [ ${#problems[@]} -eq 0 ] && return 0
  local t="Preflight FAILED.\n\nDetected GPU(s): $(gpu_names)\n\n"
  local p; for p in "${problems[@]}"; do t+="  x $p\n"; done
  t+="\nnekominer is a CUDA (NVIDIA) miner. Run it on a machine with an NVIDIA card and driver."
  if [ "${1:-}" = quiet ]; then printf '%b\n' "$t" >&2; else err "$t"; fi
  return 1
}

# ---------- process control ----------
supervisor_pid() {
  local p; p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
  return 1
}
is_running() { supervisor_pid >/dev/null; }
miner_pids() { pgrep -f "$BIN -a" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# The supervisor re-reads miner.conf before every (re)start, so config values are
# never pasted into shell code, and Settings changes apply on the next auto-restart.
write_supervisor() {
  {
    echo '#!/usr/bin/env bash'
    printf 'cd %q || exit 1\nCONF=%q BIN=%q LOGFILE=%q\n' "$DIR" "$CONF" "$BIN" "$LOGFILE"
    cat <<'EOF'
while true; do
  . "$CONF"
  # EXTRA is intentionally word-split into separate flags
  "$BIN" -a "$ALGO" -o "$POOLS" -u "$WALLET" ${DEVICES:+-d "$DEVICES"} --failback-interval "$FAILBACK" $EXTRA >> "$LOGFILE" 2>&1
  rc=$?   # capture before $(date) below resets $?
  echo "[$(date '+%F %T')] supervisor: miner exited rc=$rc - restarting in 10s" >> "$LOGFILE"
  sleep 10
done
EOF
  } > "$SUPERVISOR"
  chmod +x "$SUPERVISOR"
}

# start_core: returns 0 started/already running, 1 failed. Prints nothing.
start_core() {
  is_running && return 0
  write_supervisor
  setsid nohup "$SUPERVISOR" >> "$SUPOUT" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 3
  is_running
}

# stop_core: stop supervisor (whole process group), then sweep stragglers.
stop_core() {
  local p i; p=$(supervisor_pid) || true
  if [ -n "${p:-}" ]; then
    kill -TERM -- "-$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null
    for i in 1 2 3 4 5; do is_running || break; sleep 1; done
    is_running && kill -KILL -- "-$p" 2>/dev/null
  fi
  pkill -KILL -f "$BIN -a" 2>/dev/null
  rm -f "$PIDFILE"
}

do_start() {
  is_running && { msg "Miner is already running (supervisor PID $(supervisor_pid))."; return; }
  [ -x "$BIN" ] || { err "nekominer is not installed in $DIR.\n\nUse 'Install / update miner' first."; return; }
  if [[ "$WALLET" != btx1* ]]; then
    local v; v=$(ask "Your BTX wallet, optionally .WORKER (e.g. btx1q...xyz.rig1):" "$WALLET") || return
    WALLET=$v; save_conf
  fi
  preflight || return
  if start_core; then
    msg "Miner started.\n\nSupervisor PID: $(supervisor_pid)\nPool:   $POOLS\nWorker: ${WALLET##*.}\nAlgo:   $ALGO\n\nLog: $LOGFILE"
  else
    err "Startup failed. supervisor.out:\n\n$(tail -n 15 "$SUPOUT" 2>/dev/null | strip_ansi)"
  fi
}
do_stop() {
  if is_running || [ -n "$(miner_pids)" ]; then stop_core; msg "Miner stopped."; else msg "Miner is not running."; fi
}
do_restart() { stop_core; do_start; }

# ---------- views ----------
state_line() {   # RUNNING | CRASH LOOPING | STOPPED
  if is_running; then
    [ -n "$(miner_pids)" ] && echo RUNNING || echo "CRASH LOOPING"
  else echo STOPPED; fi
}

do_status() {
  local s st; st=$(state_line)
  s="Miner $VERSION in $DIR\n$(printf '%.0s-' {1..45})\nSTATE         $st\n"
  if is_running; then
    local sp up pids cpu; sp=$(supervisor_pid)
    up=$(ps -o etimes= -p "$sp" 2>/dev/null | tr -d ' '); pids=$(miner_pids)
    cpu=$(ps -o %cpu= -p "${pids// /,}" 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s}')
    s+="Supervisor    PID $sp (up $(pretty_time "${up:-0}"))\nMiner PID(s)  ${pids:--}\nCPU load      ${cpu:-?}%\n"
    [ "$st" = "CRASH LOOPING" ] && s+="Last error     $(last_error)\n"
  else
    [ -x "$BIN" ] && s+="Binary        installed ($(du -h "$BIN" | cut -f1))\n" || s+="Binary        NOT installed\n"
    if [ -n "$(nvml_present)" ]; then s+="NVIDIA        driver present\n"
    else s+="NVIDIA        NOT present - GPU: $(gpu_names)\n"; fi
    local e; e=$(last_error); [ -n "$e" ] && s+="Last error    $e\n"
  fi
  s+="Algo / pool   $ALGO / $POOLS\nWorker        $WALLET\nGPUs          $(gpu_line)\n"
  local acc rej live rate; read -r acc rej live rate <<< "$(miner_table totals)"
  s+="Hashrate      $rate ($live GPUs hashing)\nShares        accepted $acc | rejected $rej\n"
  s+="Log           $LOGFILE ($( [ -f "$LOGFILE" ] && size_h "$LOGFILE" || echo none))\n"
  box_fit
  s+="$(printf '%.0s-' {1..45})\n$(miner_table rows)\n\nRecent events:\n$(log_events 5)"
  whiptail --title "$APP_TITLE — STATUS" --backtitle "$DIR" --msgbox "$s" "$BOX_H" "$BOX_W"
}

do_stats() {
  [ -f "$LOGFILE" ] || { err "No log file yet."; return; }
  local acc rej live rate age s
  read -r acc rej live rate <<< "$(miner_table totals)"
  age=$(( $(date +%s) - $(stat -c %Y "$LOGFILE") ))
  s="Hashrate:       $rate ($live GPUs hashing)\nAccepted:       $acc\nRejected:       $rej\n"
  s+="Last log write: $(pretty_time "$age") ago\nLog size:       $(size_h "$LOGFILE")\n"
  box_fit
  s+="$(printf '%.0s-' {1..45})\n$(miner_table rows)\n\nRecent events:\n$(log_events 8)"
  whiptail --title "$APP_TITLE — STATS" --backtitle "$DIR" --msgbox "$s" "$BOX_H" "$BOX_W"
}

do_live_log() {
  [ -f "$LOGFILE" ] || { err "No log file yet at $LOGFILE"; return; }
  clear
  printf '\033[1;36m  LIVE LOG — %s   (Ctrl+C to return)\033[0m\n\n' "$LOGFILE"
  trap ':' INT   # Ctrl+C stops tail only; the menu's quit-on-INT trap is restored below
  tail -n 40 -f "$LOGFILE" | strip_ansi
  trap 'clear; exit 0' INT TERM
  printf '\n\033[0;90m  press Enter...\033[0m'; read -r _
}

do_view_log() {
  [ -f "$LOGFILE" ] || { err "No log file yet at $LOGFILE"; return; }
  local n; n=$(ask "How many lines from the end?" 200) || return
  tail -n "${n:-200}" "$LOGFILE" | strip_ansi | ${PAGER:-less} -R
}

# ---------- install ----------
# install_core: download + verify + install. Message on stdout; returns 0/1.
install_core() {
  local tmp="$DIR/.nekominer.dl" got; rm -f "$tmp"
  curl -fL --progress-bar -o "$tmp" "$URL" || { rm -f "$tmp"; echo "Download failed."; return 1; }
  got=$(sha256sum "$tmp" | awk '{print $1}')
  if [ "$got" != "$SHA" ]; then
    rm -f "$tmp"; echo "CHECKSUM MISMATCH - refusing to install. Expected $SHA got $got"; return 1
  fi
  if is_running; then echo "Note: miner is running; restart it to use the new binary."; fi
  chmod +x "$tmp" && mv -f "$tmp" "$BIN" && echo "Installed $BIN (sha256 OK)"
}
do_install() {
  yesno "Download nekominer $VERSION into $DIR and verify SHA-256?\n\n$SHA\n\n(An existing binary will be replaced.)" || return
  clear; echo "Downloading nekominer $VERSION ..."
  local out rc; out=$(install_core); rc=$?
  echo "$out"; sleep 1
  if [ $rc -eq 0 ]; then msg "$out"; else err "$out"; fi
}

# ---------- settings / advanced ----------
do_settings() {
  local c v
  while true; do
    box_fit
    c=$(whiptail --title "$APP_TITLE — SETTINGS" --backtitle "$DIR" --menu "Changes apply on next (re)start." "$BOX_H" "$BOX_W" 8 \
      1 "Pools         : $POOLS" \
      2 "Wallet/worker : $WALLET" \
      3 "Algorithm     : $ALGO" \
      4 "Failback (s)  : $FAILBACK" \
      5 "Extra args    : ${EXTRA:--}" \
      6 "GPUs          : ${DEVICES:-all} ($(gpu_count) detected)" \
      7 "Truncate log file" \
      0 "Back" 3>&1 1>&2 2>&3) || return
    case "$c" in
      1) v=$(ask "Pool list (comma-separated host:port, first = primary):" "$POOLS") && POOLS=$v ;;
      2) v=$(ask "Wallet.worker:" "$WALLET") && WALLET=$v ;;
      3) v=$(ask "Algorithm:" "$ALGO") && ALGO=$v ;;
      4) v=$(ask "Failback interval in seconds:" "$FAILBACK") && FAILBACK=$v ;;
      5) v=$(ask "Extra miner flags (blank for none):" "$EXTRA") && EXTRA=$v ;;
      6) v=$(ask "GPU indices to mine on, comma-separated (e.g. 0,1,3). Blank = all.\n\n$(nvidia-smi -L 2>/dev/null | cut -c1-60)" "$DEVICES") || continue
         if [[ -z "$v" || "$v" =~ ^[0-9]+(,[0-9]+)*$ ]]; then DEVICES=$v; else err "Use GPU numbers like 0,1,3 (or blank for all)."; continue; fi ;;
      7) [ -f "$LOGFILE" ] && : > "$LOGFILE" && msg "Log truncated." ;;
      0|"") return ;;
    esac
    save_conf
  done
}

do_advanced() {
  local c
  while true; do
    box_fit
    c=$(whiptail --title "$APP_TITLE — ADVANCED" --backtitle "$DIR" --menu "" "$BOX_H" "$BOX_W" 5 \
      1 "Show supervisor output" \
      2 "Show config file" \
      3 "Kill all miner processes" \
      4 "Uninstall (remove $DIR)" \
      0 "Back" 3>&1 1>&2 2>&3) || return
    case "$c" in
      1) [ -f "$SUPOUT" ] && ${PAGER:-less} -R "$SUPOUT" || msg "No supervisor output." ;;
      2) ${PAGER:-less} -R "$CONF" ;;
      3) stop_core; msg "All nekominer processes killed." ;;
      4) yesno "Stop the miner and DELETE $DIR (binary, log, config)?" || continue
         stop_core; cd / && rm -rf "$DIR"; msg "Removed $DIR."; exit 0 ;;
      0|"") return ;;
    esac
  done
}

# ---------- headless CLI ----------
cli_status() {
  local st sp up pids cpu; st=$(state_line)
  case $st in
    RUNNING|"CRASH LOOPING")
      sp=$(supervisor_pid); up=$(ps -o etimes= -p "$sp" 2>/dev/null | tr -d ' '); pids=$(miner_pids)
      cpu=$(ps -o %cpu= -p "${pids// /,}" 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s}')
      if [ "$st" = RUNNING ]; then printf '\033[1;32mMINER RUNNING\033[0m  sup=%s up=%s cpu=%s%% pids=[%s]\n' "$sp" "$(pretty_time "${up:-0}")" "${cpu:-?}" "$pids"
      else printf '\033[1;33mMINER CRASH LOOPING\033[0m  sup=%s up=%s err=%s\n' "$sp" "$(pretty_time "${up:-0}")" "$(last_error)"; fi ;;
    *) printf '\033[1;31mMINER STOPPED\033[0m\n' ;;
  esac
  if [ -n "$(nvml_present)" ]; then printf '\033[0;32mpreflight OK\033[0m  GPU: %s\n' "$(gpu_names)"
  else printf '\033[1;31mPREFLIGHT FAIL\033[0m no libnvidia-ml.so.1 - GPU: %s (nekominer is CUDA-only)\n' "$(gpu_names)"; fi
  printf 'pool   %s\nalgo   %s\nworker %s\nlog    %s\n' "$POOLS" "$ALGO" "$WALLET" "$LOGFILE"
  local acc rej live rate; read -r acc rej live rate <<< "$(miner_table totals)"
  printf 'gpus   %s\n' "$(gpu_line)"
  printf 'hash   %s (%s GPUs hashing)   shares accepted %s / rejected %s\n' "$rate" "$live" "$acc" "$rej"
  miner_table rows | sed 's/^/       /'
  [ -f "$LOGFILE" ] && { echo "--- tail ---"; tail -n "${1:-8}" "$LOGFILE" | strip_ansi; }
  return 0
}

cli_start() {
  [ -x "$BIN" ] || { echo "not installed: $BIN (run --install)" >&2; return 1; }
  preflight quiet || return 2
  is_running && { echo "already running"; return 0; }
  if start_core; then echo "started sup=$(supervisor_pid)"; else echo "start failed" >&2; return 1; fi
}

case "${1:-}" in
  --status)    cli_status "${2:-8}"; exit 0 ;;
  --preflight) preflight quiet && echo "preflight OK"; exit $? ;;
  --start)     cli_start; exit $? ;;
  --stop)      stop_core; echo stopped; exit 0 ;;
  --restart)   stop_core; cli_start; exit $? ;;
  --install)   install_core; exit $? ;;
  -h|--help)
    cat <<'EOF'
miner-btx.sh                      interactive menu (whiptail)
  --status [lines]                one-shot status + log tail
  --preflight                     check NVIDIA driver / binary
  --start | --stop | --restart    headless control
  --install                       download + verify + install
Env: BTX_MINER_DIR (default /opt/btx), BTX_WALLET (default wallet on first run)
EOF
    exit 0 ;;
  "") ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 64 ;;
esac

# ---------- interactive main loop ----------
ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  echo "whiptail not found - installing (apt update && apt install whiptail)..."
  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "Need root to install whiptail. Re-run as root." >&2; return 1; }
    SUDO=sudo
  fi
  command -v apt-get >/dev/null 2>&1 || { echo "apt-get not found; install whiptail manually." >&2; return 1; }
  $SUDO apt-get update && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y whiptail \
    || { echo "whiptail installation failed." >&2; return 1; }
  command -v whiptail >/dev/null 2>&1
}
ensure_whiptail || exit 1

trap 'clear; exit 0' INT TERM

# First-run / not-running prompts
if [ ! -x "$BIN" ]; then
  yesno "nekominer is not installed in $DIR.\n\nInstall it now?" && do_install
fi
if [ -x "$BIN" ] && ! is_running; then
  yesno "The miner is not running.\n\nStart mining now?" && do_start
fi
while true; do
  state=$(state_line); [ -z "$(nvml_present)" ] && state="$state | NO GPU DRIVER"
  # whiptail menus can't activate on a keypress, so the main menu reads a single key.
  clear
  printf '\033[1;36m=== %s  %s ===\033[0m\n' "$APP_TITLE" "$VERSION"
  printf '\033[0;90m%s | %s\033[0m\n' "$POOLS" "$DIR"
  printf 'State: \033[1m%s\033[0m\n\n' "$state"
  cat <<'MENU'
  1) Status dashboard
  2) Start mining
  3) Stop mining
  4) Restart
  5) Live log (follow)
  6) View log
  7) Share / hashrate summary
  8) Settings (pools, wallet, algo)
  9) Install / update miner (verify sha256)
  A) Advanced / uninstall
  0) Quit  (or q)

MENU
  printf 'Press a key: '
  IFS= read -rsn1 choice || break
  [ "$choice" = q ] || [ "$choice" = Q ] && choice=0
  case "$choice" in
    1) do_status ;;   2) do_start ;;    3) do_stop ;;
    4) do_restart ;;  5) do_live_log ;; 6) do_view_log ;;
    7) do_stats ;;    8) do_settings ;; 9) do_install ;;
    A|a) do_advanced ;;
    0) break ;;
  esac
done
clear
