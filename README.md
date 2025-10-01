📘 Documentation – update-vms.sh

Proxmox® is a registered trademark of Proxmox Server Solutions GmbH.

I am no member of the Proxmox Server Solutions GmbH. This is not an official programm from Proxmox!

🔎 Purpose

This script automates updates for LXC containers and QEMU virtual machines in Proxmox VE.
It runs the appropriate package update commands (yum or apt) inside the guest using pct exec (for containers) or qm guest exec (for VMs).

Proxmox tags are used to determine which package manager to run and to exclude specific systems (e.g., Windows).

⚙️ Features

Retrieves all VMs and CTs on the local Proxmox node.

Processes only those that are running.

Reads tags for each VM/CT:

apt → run apt -y update && apt -y upgrade.

yum → run yum -y update.

windows → skip (no updates).

no recognized tag → skip.

Logs output to the console (can easily be extended to log files).

📥 Requirements

On the Proxmox host:

jq must be installed:

apt install -y jq


For QEMU VMs:

The guest OS must have QEMU Guest Agent installed:

Debian/Ubuntu: apt install qemu-guest-agent

CentOS/RHEL: yum install qemu-guest-agent

Enable QEMU Guest Agent in Proxmox GUI:

VM → Options → QEMU Guest Agent = Enabled
