# 🖥️ Proxmox VM/CT Auto-Update Script

This repository contains a Bash script that automatically updates **LXC containers** and **QEMU virtual machines** on a Proxmox VE host.  
It uses Proxmox **tags** to determine which package manager to run (`apt` or `yum`) and can skip systems such as Windows VMs.

---

## ✨ Features

- Updates both **LXC containers** (`pct exec`) and **QEMU VMs** (`qm guest exec`).
- Runs the correct package manager based on **Proxmox tags**:
  - `apt` → Debian/Ubuntu systems
  - `yum` → CentOS/RHEL systems
  - `windows` → Skips updates
- Processes **only running** guests.
- Easy to extend and automate via cron.

---

## ⚙️ Requirements

### On the Proxmox host
- Install `jq`:
\`\`\`bash
apt install -y jq
\`\`\`

### For QEMU VMs
- Install **QEMU Guest Agent** inside the VM:

Debian/Ubuntu:
\`\`\`bash
apt install qemu-guest-agent
\`\`\`

CentOS/RHEL:
\`\`\`bash
yum install qemu-guest-agent
\`\`\`

- Enable the Guest Agent in Proxmox GUI:  
  **VM → Options → QEMU Guest Agent → Enabled**

---

## 🏷️ Using Tags

| Tag       | Action                                    |
|-----------|-------------------------------------------|
| `apt`     | Runs \`apt update && apt upgrade\`         |
| `yum`     | Runs \`yum update\`                        |
| `windows` | Skips the VM/CT entirely (no updates run)|

### CLI Examples
\`\`\`bash
pct set 201 --tags apt
qm set 101 --tags yum
qm set 150 --tags windows
\`\`\`

---

## 🚀 Usage

Run manually:
\`\`\`bash
./scripts/update-vms.sh
\`\`\`

Schedule with cron (e.g., every night at 3 AM):
\`\`\`bash
crontab -e
\`\`\`

Add this line:
\`\`\`bash
0 3 * * * /root/proxmox-vm-update/scripts/update-vms.sh >> /var/log/update-vms.log 2>&1
\`\`\`

---

## 📊 Example Output

\`\`\`
▶ Processing 101 (qemu) with tags: apt
   → qm apt update/upgrade
▶ Processing 201 (lxc) with tags: yum
   → pct yum update
🟦 Skipping 150 (qemu) - tag: windows
⚪ Skipping 202 (lxc) - status stopped
\`\`\`

---

## 🛠️ Troubleshooting

- **\`qm guest exec\` fails** → Ensure QEMU Guest Agent is installed inside the VM and enabled in Proxmox.  
- **Tags not applied** → Verify VM/CT has correct tags:
\`\`\`bash
qm config <VMID> | grep tags
pct config <CTID> | grep tags
\`\`\`
- **Containers update but VMs don’t** → Most likely missing guest agent or permissions.  

---

## 📄 License & Disclaimer

MIT License – feel free to use and modify.  

**Disclaimer:**  
Proxmox® is a registered trademark of **Proxmox Server Solutions GmbH**.  
I am not a member of Proxmox Server Solutions GmbH. This is **not** an official program from Proxmox!
