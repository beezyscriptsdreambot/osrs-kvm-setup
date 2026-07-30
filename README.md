# osrs-kvm-setup

One-shot setup for a Linux KVM: a lightweight XFCE desktop, xrdp with autostart, Eclipse Temurin JDK 11 and Google Chrome. Once it finishes you can connect over Remote Desktop and launch your preferred OSRS client right away.

Everything happens in a single run of `deploy.sh`. Three things are asked up front (RDP user, password, ufw + fail2ban), after that the rest runs unattended.

## Distro

The target system is **Ubuntu Server 24.04 LTS** (amd64). Ubuntu 22.04 LTS as well as Debian 12/13 work with the same script — the distribution is detected automatically.

XFCE is not a distribution but the desktop environment, and it is exactly the right choice here: lightweight, X11 based and therefore fully compatible with xrdp. GNOME and Wayland regularly cause black screens and session conflicts with xrdp, so install **Ubuntu Server**, not Ubuntu Desktop.

When installing Ubuntu Server:

- Use the normal server installation, not the "minimized" profile
- Enable "Install OpenSSH server"
- Do not select any desktop packages or snaps — this script takes care of that

### Recommended VM resources

| | Minimum | Recommended |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 2 GB | 4–8 GB (Java clients are hungry) |
| Disk | 15 GB | 25 GB |

XFCE idles at roughly 400–500 MB of RAM, the rest is left for the client and the browser.

## Requirements

- A fresh Ubuntu Server 24.04/22.04 install (or Debian 12/13), amd64 recommended
- Root or sudo access
- Network access from the VM

A user for the RDP session is requested during the run and created if it does not exist yet.

## Installation

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/beezyscriptsdreambot/osrs-kvm-setup.git
cd osrs-kvm-setup
chmod +x deploy.sh
sudo ./deploy.sh
```

Copying just the script over, for example with `scp deploy.sh user@vm:~/`, works the same way — it is self-contained.

### What you are asked

All questions come first so the rest of the run needs no supervision:

1. **Username for the RDP session** — defaults to the current sudo user. Created if missing, including the sudo group. `root` is rejected.
2. **Password** — entered twice, at least 8 characters, never echoed. If the user already has a password you are asked whether to replace it.
3. **Install ufw + fail2ban?** — defaults to yes.

The run takes 5–15 minutes depending on the connection.

### Fully unattended

Every variable you preset skips the matching question:

```bash
sudo RDP_USER=osrs RDP_PASSWORD='YourStrongPassword' INSTALL_UFW=true INSTALL_FAIL2BAN=true ./deploy.sh
```

## Options

| Variable | Default | Meaning |
|---|---|---|
| `RDP_USER` | asked | User for the RDP session. Created if missing. |
| `RDP_PASSWORD` | asked | Password of the RDP user. |
| `RDP_PORT` | `3389` | Listening port of xrdp. |
| `INSTALL_UFW` | asked | Install and enable the ufw firewall. |
| `INSTALL_FAIL2BAN` | asked | Install fail2ban and configure it for sshd + xrdp. |
| `INSTALL_JAVA` | `true` | Install Temurin JDK 11. |
| `INSTALL_CHROME` | `true` | Install Google Chrome. |
| `INSTALL_DREAMBOT` | `true` | Download the DreamBot launcher to `~/DreamBot/DBLauncher.jar`. |
| `DREAMBOT_URL` | `https://dreambot.org/DBLauncher.jar` | Source of the launcher jar. |
| `XFCE_EXTRAS` | `false` | Also install `xfce4-goodies` (more panel plugins and tools). |
| `DISABLE_DISPLAY_MANAGER` | `true` | Disables LightDM/GDM and switches to `multi-user.target`. Saves RAM, since nobody uses the local console on a headless KVM. |

`sudo ./deploy.sh --help` prints the same overview.

Without a terminal (cloud-init, CI pipeline) the questions are skipped automatically and the defaults apply.

## Connecting

When the run finishes the script prints the IP, port and user.

| Client | How |
|---|---|
| Windows | "Remote Desktop Connection" (`mstsc`) → `IP:3389` |
| macOS | "Windows App" (formerly Microsoft Remote Desktop) from the App Store |
| Linux | Remmina or FreeRDP: `xfreerdp /v:IP /u:USER` |

The session type in the xrdp login screen has to be `Xorg` (the default).

## Security

If you answer yes to the security question:

- **ufw** is installed and enabled. Only the SSH port (read from `sshd_config` so you cannot lock yourself out) and the RDP port are allowed.
- **fail2ban** watches `sshd` and xrdp. After 5 failed attempts within 10 minutes the IP is banned for an hour. A dedicated xrdp filter is written to `/etc/fail2ban/filter.d/xrdp-auth.conf` and reads `/var/log/xrdp-sesman.log`.

Ubuntu 24.04 no longer writes `/var/log/auth.log` — the script detects this and switches the sshd jail to the systemd backend automatically, including `python3-systemd`.

Even so: port 3389 does not belong on the open internet. An SSH tunnel is considerably safer, it keeps the RDP port firewalled off entirely and the connection goes to `localhost:3389`:

```bash
ssh -L 3389:localhost:3389 user@vm-ip
```

Alternatively whitelist your own IP:

```bash
sudo ufw allow from YOUR.IP.ADDRESS to any port 3389 proto tcp
```

Show banned IPs:

```bash
sudo fail2ban-client status sshd
```

## What the script does

1. Checks for root and detects the distribution (Ubuntu/Debian and derivatives)
2. Asks for the RDP user, password and ufw/fail2ban, creates the user and sets the password
3. `apt update` and `apt full-upgrade -y` — `full-upgrade` rather than plain `upgrade`, so held-back changes such as kernel updates come along too
4. Base packages: `ca-certificates`, `curl`, `wget`, `gnupg`, `apt-transport-https`
5. XFCE desktop: `xfce4`, `xfce4-terminal`, `thunar`, `dbus-x11`, `xfce4-power-manager`, fonts, polkit
6. `xrdp` + `xorgxrdp`, adds the xrdp user to the `ssl-cert` group
7. Writes `/etc/xrdp/startwm.sh` (with `unset DBUS_SESSION_BUS_ADDRESS` / `XDG_RUNTIME_DIR`, otherwise the screen stays grey after login) and `~/.xsession` with `startxfce4`
8. Sets `allowed_users=anybody` in `/etc/X11/Xwrapper.config` so Xorg is allowed to start inside the RDP session
9. Polkit rules against the recurring "Authentication required" popups (colord, PackageKit)
10. Disables the screensaver, lock screen and DPMS — otherwise the RDP session appears frozen after a few minutes
11. Eclipse Temurin JDK 11 from the official Adoptium repository, including `JAVA_HOME` in `/etc/profile.d/temurin11.sh` and `update-alternatives`
12. Google Chrome from the official Google repository (Chromium on arm64, since Google does not ship Chrome for it)
13. DreamBot launcher, downloaded to `~/DreamBot/DBLauncher.jar`, plus a `dreambot` command and a desktop entry
14. ufw and fail2ban, if requested
15. Disables the display manager
16. Enables `xrdp` and `xrdp-sesman` via systemd → autostart after every reboot
17. Prints a summary with IP, port, user and versions

The script is idempotent: running it a second time does no harm. The original `startwm.sh` is kept as `/etc/xrdp/startwm.sh.orig`.

## DreamBot

The launcher is downloaded to `~/DreamBot/DBLauncher.jar`, which is also where DreamBot keeps its own data. Inside the RDP session you can start it from the desktop icon, from the applications menu, or from a terminal:

```bash
dreambot
```

That wrapper lives in `/usr/local/bin/dreambot` and pins the Temurin 11 binary explicitly, so the client keeps working even if another JDK becomes the system default later. The equivalent manual call is:

```bash
java -jar ~/DreamBot/DBLauncher.jar
```

DreamBot requires Java 11, which is why Temurin 11 is part of this setup. Running with `INSTALL_JAVA=false` leaves the launcher unusable.

## After the installation

```bash
java -version
google-chrome-stable --version
systemctl status xrdp
```

`JAVA_HOME` is available after a fresh login, or immediately via `source /etc/profile.d/temurin11.sh`.

## Troubleshooting

"Unable to connect", error code `0x204` — the client never reached port 3389, this happens before any authentication. Work through it from the outside in. First check from your own machine whether the port is reachable at all:

```bash
nc -z -w 5 YOUR.VM.IP 3389
```

If that fails while SSH still works, check on the VM in this order:

```bash
sudo ss -tlnp | grep 3389
```

No output means xrdp is not listening — `sudo systemctl status xrdp` and `sudo systemctl restart xrdp`. If it only shows `127.0.0.1:3389`, remove the `address=` line from `/etc/xrdp/xrdp.ini` so it binds to all interfaces.

If the service log shows a nonsense port such as `listening to port 338933893389`, the `port=` line in `/etc/xrdp/xrdp.ini` is mangled. Repair it and restart:

```bash
sudo sed -i '0,/^port=/s/^port=.*/port=3389/' /etc/xrdp/xrdp.ini && sudo systemctl restart xrdp
```

```bash
sudo ufw status verbose
```

`3389/tcp ALLOW` has to be listed. If not: `sudo ufw allow 3389/tcp`.

If the port is listening and ufw allows it but the connection still times out, the block is upstream at your hosting provider — open 3389/tcp in their firewall or security group panel.

Grey or black screen after login — usually an old session is still around. End all sessions of the user and reconnect:

```bash
sudo pkill -u USER -f xfce4-session
```

"Login failed for display 0" — the user is still logged into a local X session. Disable the display manager (the script does this by default) and reboot.

Connection closes immediately — check the logs:

```bash
sudo journalctl -u xrdp -u xrdp-sesman -n 100 --no-pager
```

Also look at `/var/log/xrdp-sesman.log` and `~/.xorgxrdp.10.log`.

Locked yourself out — log in through your provider's KVM console and run `sudo fail2ban-client set sshd unbanip YOUR.IP`.

Chrome does not start — Chrome refuses to run as root, always start it as the regular RDP user.

No Adoptium repository for the codename — the script checks this automatically and falls back to `jammy` (Ubuntu) or `bookworm` (Debian). The packages are compatible.

## License

MIT
