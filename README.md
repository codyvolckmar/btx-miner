# BTX Miner

A single-file Bash control panel for mining **BTX** (`btxv4`) on NVIDIA GPUs with
[nekominer](https://github.com/nr800/nekominer).

It installs and verifies the miner, keeps it running, and gives you a status
dashboard. Use the keyboard menu, or run it headless over SSH or cron.

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/codyvolckmar/btx-miner/main/install.sh | sudo BTX_WALLET=btx1YOURADDRESS.rig1 bash
```

This installs the control panel as `btx-miner`. It downloads nekominer, verifies
its SHA-256, and starts mining once the NVIDIA checks pass. Leave out
`BTX_WALLET=...` to set the wallet later in the menu (`sudo btx-miner`).
[Read install.sh](install.sh) before you pipe it to a shell.

```
=== BTX MINER  v0.21.0 ===
btxv4.ninjaraider.com:44950,btx-pool.com:3334 | /opt/btx
State: RUNNING

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
```

## Requirements

- x86_64 Linux
- NVIDIA GPU, compute capability 6.0+ (Pascal / Tesla P100 or newer)
- NVIDIA driver 525+ (`nvidia-smi` and `libnvidia-ml.so.1` present)
- `bash`, `curl`, `sha256sum`, and `whiptail` (installed for you through `apt` if missing)

## Manual install

```bash
curl -fsSLO https://raw.githubusercontent.com/codyvolckmar/btx-miner/main/miner-btx.sh
chmod +x miner-btx.sh
sudo ./miner-btx.sh
```

On first run it offers to download nekominer, asks for your wallet, and starts mining.

Headless setup:

```bash
sudo BTX_WALLET=btx1youraddress.rig1 ./miner-btx.sh --install
sudo ./miner-btx.sh --start
sudo ./miner-btx.sh --status
```

## Commands

| Command | What it does |
|---|---|
| `./miner-btx.sh` | Interactive menu |
| `--status [lines]` | One-shot status plus the last N log lines |
| `--preflight` | Check the binary, NVIDIA driver, and wallet |
| `--start` / `--stop` / `--restart` | Headless control |
| `--install` | Download, verify, and install nekominer |

| Env var | Default | Meaning |
|---|---|---|
| `BTX_MINER_DIR` | `/opt/btx` | Where everything lives. Use a home directory to run without root. |
| `BTX_WALLET` | (none) | Wallet used when `miner.conf` is first created |

## How it works

Everything lives in one directory (`/opt/btx` by default):

```
/opt/btx/
├── nekominer        miner binary (pinned version, SHA-256 verified)
├── miner.conf       your settings (plain shell variables)
├── supervisor.sh    generated restart loop
├── supervisor.pid   PID of the running supervisor
├── supervisor.out   supervisor stdout/stderr
└── miner.log        miner output
```

**Install.** The script pins one nekominer release (`VERSION`) and its SHA-256
checksum (`SHA`). It downloads the binary to a temp file and checks the hash. It
installs only if the hash matches. A tampered or corrupted download is rejected.

**Config.** `miner.conf` holds `POOLS`, `WALLET`, `ALGO`, `FAILBACK`, and `EXTRA`.
The Settings menu writes it with shell-safe quoting. You can also edit it by hand.

**Supervisor.** Start writes a small `supervisor.sh` and launches it detached
(`setsid nohup`), so it survives logout. The supervisor loops forever:

1. Re-read `miner.conf`
2. Run `nekominer -a $ALGO -o $POOLS -u $WALLET --failback-interval $FAILBACK $EXTRA`
3. If the miner exits, log the exit code, wait 10 s, and go back to step 1

Because the config is re-read on every loop, settings changes apply on the next
restart.

**Pools and failover.** `POOLS` is a comma-separated list, primary first. nekominer
fails over to the next pool when one drops. Every `FAILBACK` seconds it tries to
return to the primary. The default is ninjaraider, which charges a **0% dev fee**
for BTX, with btx-pool.com (2% fee) as backup.

**Stop.** Stop sends SIGTERM to the supervisor's whole process group and waits up
to 5 s. It then sends SIGKILL and sweeps any leftover `nekominer` processes.

**Status.** The dashboard reports one of three states:

- `RUNNING`: supervisor and miner both alive
- `CRASH LOOPING`: supervisor alive but no miner process. The miner keeps dying,
  and the dashboard shows the last error from the log.
- `STOPPED`

It also shows uptime, CPU load, and accepted and rejected share counts from the
log. The stats view also shows the latest hashrate.

**Preflight.** Before starting, it checks for the binary, NVML
(`libnvidia-ml.so.1`), `nvidia-smi`, and a `btx1…` wallet. If any are missing, it
tells you what's wrong instead of crash-looping.

## Overclocking

nekominer 0.21 has built-in NVIDIA OC flags. Add them under **Settings → Extra
args**. Example for one RTX 3070 (tune per card; OC flags need root):

```
--lock-cclock 1560 --lock-mclock 810 --cclock 180 --mclock 500 --pl 147 --fan 65 --oc-exit restore
```

See the [nekominer README](https://github.com/nr800/nekominer) for every flag.

## Updating nekominer

Change `VERSION` and `SHA` at the top of `miner-btx.sh`. The new hash is in the
release's `SHA256SUMS` file, on the `nekominer` line. Then choose **9) Install /
update** and **4) Restart**.

## Notes

- Does not start on boot by itself. To get that, add a cron entry:
  `@reboot /path/to/miner-btx.sh --start` (in root's crontab when using `/opt/btx`).
- `miner.log` is not rotated. Truncate it from Settings when it gets large.
- `miner.conf` is sourced as shell code. Keep the directory writable only by you
  or root.

## Disclaimer

This project is not affiliated with nekominer or any pool. nekominer is a
closed-source third-party binary. Run it at your own risk.

## License

MIT
