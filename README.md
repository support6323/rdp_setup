# Ubuntu Headless VPS Multi-User xRDP + XFCE + Falkon Setup

A POSIX-compliant shell automation script (`setup_xrdp.sh`) that converts a fresh headless **Ubuntu 22.04 / 24.04** KVM/VPS into a secure, low-latency, multi-user Remote Desktop server supporting **1 to 3+ concurrent graphical sessions**.

---

## Key Features

* **Interactive Multi-User Provisioning:** Prompts for swap size, user count, usernames, and hidden passwords upfront before unattended installation.
* **Strict Least-Privilege Security:**
  * **No `sudo` access:** RDP accounts are standard unprivileged users.
  * **SSH Tunnel-Only Restriction:** RDP users belong to the `rdp-tunnel` group and use `/usr/local/bin/rdp-tunnel-shell` with a modular `/etc/ssh/sshd_config.d/90-rdp-tunnel-only.conf` policy—allowing local TCP port forwarding strictly to `127.0.0.1:3389` while blocking interactive SSH shell execution, X11 forwarding, and agent forwarding.
  * **Zero Public RDP Exposure:** xRDP binds exclusively to `127.0.0.1:3389`, and UFW blocks public port `3389`.
  * **Brute-Force Protection:** Enables **Fail2Ban** (`sshd` jail) without altering your primary `/etc/ssh/sshd_config` port or root authentication rules, and leaves your server timezone untouched.
* **Low-Latency WAN Optimization:**
  * Lightweight **XFCE4** desktop with window compositing disabled (`use_compositing=false`) to eliminate drag/render lag over remote connections.
  * Tuned `/etc/xrdp/xrdp.ini` (`max_bpp=16`, `use_compression=yes`, `tcp_nodelay=true`, `tcp_keepalive=true`).
  * Automatic cleanup of disconnected/abandoned RDP sessions after 2 hours (`DisconnectedTimeLimit=7200`) to reclaim RAM.
* **Pre-Configured Falkon Browser:**
  * Installs **Falkon** (lightweight Qt/WebEngine browser) and registers it as the system default browser (`x-www-browser`, `xdg-settings`, and XFCE `helpers.rc`).
  * Places a pre-trusted `Falkon.desktop` shortcut (`metadata::trusted true`) on every user's Desktop so no "Untrusted application launcher" prompt appears.
* **Built-In User Management CLI (`/usr/local/bin/manage-rdp-user`):** Add, remove, or list RDP users anytime after installation with a single command.

---

## Hardware & RAM Sizing Guide

Because VPS/KVM instances render graphics on CPU/RAM without a dedicated GPU:

| Concurrent Users | Workload Type | Minimum RAM | Recommended RAM | vCPUs | Storage |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1–3 Users** | Light browsing (Falkon), terminal, basic tools | **4 GB** (+ 4 GB Swap) | **6 GB – 8 GB** | 2–4 vCPUs | 40 GB NVMe |
| **1–3 Users** | Heavy multi-tab browsing & parallel apps | **8 GB** (+ 4 GB Swap) | **12 GB – 16 GB** | 4–6 vCPUs | 60+ GB NVMe |

---

## Quick Start Installation

1. **Upload or clone this repository onto your Ubuntu 22.04 / 24.04 VPS:**
   ```sh
   chmod +x setup_xrdp.sh
   sudo ./setup_xrdp.sh
   ```

2. **Follow the interactive prompts:**
   * Enter desired swap file size (press `Enter` for default `4G`).
   * Enter the number of RDP users (`1`–`10`).
   * Enter each username and password.

3. **Verify services after completion:**
   ```sh
   ss -tlpn | grep 3389
   sudo fail2ban-client status sshd
   sudo manage-rdp-user list
   ```

---

## How to Connect from a Client PC

Because port `3389` is bound strictly to `127.0.0.1` on the server, users connect through an encrypted SSH local port forward:

### 1. Open an SSH Tunnel (Windows PowerShell, macOS, or Linux)
```sh
ssh -L 3390:127.0.0.1:3389 -N <username>@YOUR_SERVER_IP
```
*(Authenticate with the RDP user's password. Keep this terminal window open while connected; `-N` keeps the tunnel active without requesting an interactive shell).*

> **Tip for multiple users on the same client PC:** Forward different local ports per session (e.g., `-L 3391:127.0.0.1:3389` for user 2, `-L 3392:127.0.0.1:3389` for user 3).

### 2. Connect Your RDP Client
* **Windows (`mstsc.exe`):** Connect to `127.0.0.1:3390`
* **Linux / macOS (Remmina / Windows App):** Connect to `127.0.0.1:3390`

**Recommended Client Display Settings for Lowest Lag:**
* **Color Depth:** High Color (16-bit)
* **Experience:** Uncheck Desktop background, Font smoothing, Desktop composition, and Visual styles.

---

## Managing RDP Users Post-Install

Use the installed `/usr/local/bin/manage-rdp-user` utility anytime as `root` or via `sudo`:

* **Add a new non-sudo, tunnel-only RDP user:**
  ```sh
  sudo manage-rdp-user add newuser
  ```
  *(Automatically configures XFCE, disables compositing, sets Falkon as default browser, and creates a trusted Desktop shortcut).*

* **Remove an existing RDP user (kills active sessions & deletes `/home/<user>`):**
  ```sh
  sudo manage-rdp-user remove olduser
  ```

* **List all configured RDP users:**
  ```sh
  sudo manage-rdp-user list
  ```

---

## Repository Contents

* `setup_xrdp.sh` — Main POSIX-compliant installation, hardening, and user provisioning script.
* `README.md` — Architecture overview, setup instructions, client connection guide, and user management reference.

## License

MIT License
