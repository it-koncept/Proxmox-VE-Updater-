# 🖥️ Proxmox VE Updater

Bash script that updates **LXC containers** and **QEMU virtual machines** on a Proxmox VE host.
It uses Proxmox **tags** to decide which package manager to run and skips e.g. Windows VMs.

---

## ✨ Features

- Updates **LXC containers** (`pct exec`) and **QEMU VMs** (`qm guest exec`) on the local node.
- Package manager chosen by **exact tag match** (tags are `;`-separated in PVE):
  - `apt` → `apt-get update && upgrade` (noninteractive, keeps existing conffiles)
  - `yum` → `dnf -y update` if the guest has dnf, otherwise `yum -y update`
  - `windows` → skipped entirely
- Only touches **running** guests.
- Single-instance guard (`flock`) — safe if a cron run overlaps the previous one.
- Per-guest exit codes, timestamped log lines, end summary, non-zero exit code on failures.
- `--dry-run` mode to preview what would happen.

---

## ⚙️ Requirements

### On the Proxmox host
Install `jq`:

```bash
apt install -y jq
```

### For QEMU VMs
Install **QEMU Guest Agent** inside the VM:

Debian/Ubuntu:

```bash
apt install qemu-guest-agent
```

CentOS/RHEL/Fedora:

```bash
dnf install qemu-guest-agent
```

Enable the Guest Agent in Proxmox:
**VM → Options → QEMU Guest Agent → Enabled**

(Without it, `qm guest exec` fails with "No QEMU guest agent configured" — v1 of this
script hid that because it never checked exit codes.)

---

## 🏷️ Using Tags

Tag matching is **exact** (case-insensitive) per `;`-separated tag — a tag like
`compat` does **not** match `apt`.

| Tag       | Action                                     |
|-----------|--------------------------------------------|
| `apt`     | `apt-get update && apt-get upgrade`        |
| `yum`     | `dnf -y update` (falls back to `yum`)      |
| `windows` | Skips the VM/CT entirely (no updates run)  |

CLI examples:

```bash
pct set 201 --tags apt
qm set 101 --tags yum
qm set 150 --tags windows
```

---

## 🚀 Usage

Preview first (recommended):

```bash
./update-vms.sh --dry-run
```

Run manually:

```bash
./update-vms.sh
```

Schedule with cron (e.g. every night at 3 AM):

```bash
crontab -e
```

```cron
0 3 * * * /root/update-vms.sh >> /var/log/update-vms.log 2>&1
```

### Options / environment

| Setting             | Default   | Meaning                                   |
|---------------------|-----------|-------------------------------------------|
| `--dry-run`         | off       | Print what would run, change nothing      |
| `PVE_NODE`          | hostname  | Only update guests on this node           |
| `QEMU_EXEC_TIMEOUT` | 1800      | `qm guest exec --timeout` in seconds      |

> **Why the timeout matters:** `qm guest exec` defaults to **30 seconds**, which kills
> long package installs mid-run and can leave dpkg/rpm in a broken state. This script
> raises it to 30 minutes by default.

---

## 📊 Example Output

```
[2026-10-15 03:00:01] === update-vms start (node=prod-node) ===
[2026-10-15 03:00:02] ▶ Updating 107 (lxc) [apt]
[2026-10-15 03:01:10] ▶ Updating 101 (qemu) [yum/dnf]
[2026-10-15 03:01:45]    ✗ failed (rc=1):
     | Error: QEMU guest agent is not running
[2026-10-15 03:01:45] 🟦 Skipping 150 (qemu) - tag: windows
[2026-10-15 03:01:45] ⚪ Skipping 149 (lxc) - status stopped
[2026-10-15 03:01:45] === done: 2 updated, 1 failed, 2 skipped ===
```

---

## 🛠️ Troubleshooting

- **`qm guest exec` fails** → Ensure QEMU Guest Agent is installed inside the VM *and* enabled in Proxmox.
- **Tags not applied** → Verify:

```bash
qm config <VMID> | grep tags
pct config <CTID> | grep tags
```

- **Containers update but VMs don't** → Missing guest agent or the agent timeout is hit.
- **"Another update-vms run is already in progress"** → A previous run is still going (flock guard); wait for it or check `ps aux | grep update-vms`.

---

## 🔒 Security notes

- Runs as root on the host; executes only fixed, hardcoded package-manager commands inside guests — tags select *which* guests and *which* command, never arbitrary input.
- VMIDs are validated as numeric before any `pct`/`qm` call.
- The node name is passed to `jq` via `--arg`, never interpolated into the filter.
- No credentials, no network access; everything stays on the host.

---

## 📄 License & Disclaimer

MIT License (see [LICENSE](LICENSE)).

**Disclaimer:**
Proxmox® is a registered trademark of **Proxmox Server Solutions GmbH**.
This is **not** an official program from Proxmox Server Solutions GmbH.
