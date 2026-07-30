# osrs-kvm-setup

One-shot setup for a Linux KVM: XFCE desktop, xrdp with autostart, Eclipse Temurin JDK 11, Google Chrome and the DreamBot launcher. Run it once, then connect over Remote Desktop and start your client.

Target system is **Ubuntu Server 24.04 LTS** (amd64). Ubuntu 22.04 and Debian 12/13 work too — the distro is detected automatically. Install Ubuntu **Server**, not Desktop: GNOME and Wayland break xrdp.

Recommended VM: 2–4 vCPU, 4 GB RAM, 25 GB disk.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/beezyscriptsdreambot/osrs-kvm-setup/main/deploy.sh | sudo bash
```

Or clone it:

```bash
sudo apt update && sudo apt install -y git && git clone https://github.com/beezyscriptsdreambot/osrs-kvm-setup.git && cd osrs-kvm-setup && sudo bash deploy.sh
```

Three questions come first, then it runs unattended for 5–15 minutes:

1. **Username** for the RDP session — created if missing, `root` is rejected
2. **Password** — twice, at least 8 characters
3. **Install ufw + fail2ban?** — defaults to yes

Rerunning is safe; the script is idempotent.

## Connect

Use the IP and user printed in the summary. Port 3389, session type `Xorg`.

| Client | How |
|---|---|
| Windows | Remote Desktop Connection (`mstsc`) |
| macOS | Windows App (formerly Microsoft Remote Desktop) |
| Linux | Remmina, or `xfreerdp /v:IP /u:USER` |

Start DreamBot inside the session with `dreambot` or the desktop icon. The launcher lives in `~/DreamBot/DBLauncher.jar` and is pinned to Temurin 11.

## Options

Presetting a variable skips the matching question.

| Variable | Default | Meaning |
|---|---|---|
| `RDP_USER` | asked | User for the RDP session |
| `RDP_PASSWORD` | asked | Password of that user |
| `RDP_PORT` | `3389` | Listening port of xrdp |
| `INSTALL_UFW` | asked | Install and enable ufw |
| `INSTALL_FAIL2BAN` | asked | Install fail2ban for sshd + xrdp |
| `INSTALL_JAVA` | `true` | Temurin JDK 11 |
| `INSTALL_CHROME` | `true` | Google Chrome (Chromium on arm64) |
| `INSTALL_DREAMBOT` | `true` | DreamBot launcher |
| `DREAMBOT_URL` | dreambot.org | Source of the launcher jar |
| `XFCE_EXTRAS` | `false` | Also install `xfce4-goodies` |
| `DISABLE_DISPLAY_MANAGER` | `true` | Disable LightDM/GDM, boot to `multi-user.target` |

Fully unattended:

```bash
sudo RDP_USER=osrs RDP_PASSWORD='YourStrongPassword' INSTALL_UFW=true INSTALL_FAIL2BAN=true ./deploy.sh
```

## Security

ufw allows only SSH (port read from `sshd_config`) and RDP. fail2ban bans an IP for an hour after 5 failed attempts in 10 minutes, watching both `sshd` and `/var/log/xrdp-sesman.log`.

Port 3389 on a public IP means every bot on the internet sees your login prompt. An SSH tunnel avoids that — keep 3389 firewalled and connect to `localhost:3389`:

```bash
ssh -L 3389:localhost:3389 user@vm-ip
```

## Troubleshooting

**"Unable to connect", error 0x204** — the client never reached port 3389. Check from your machine with `nc -z -w 5 YOUR.VM.IP 3389`, then on the VM:

```bash
sudo ss -tlnp | grep 3389; sudo ufw status
```

No output from `ss` means xrdp is not listening — check `sudo systemctl status xrdp`. A nonsense port such as `338933893389` in the log means `xrdp.ini` is mangled; repair it:

```bash
sudo sed -i '0,/^port=/s/^port=.*/port=3389/' /etc/xrdp/xrdp.ini && sudo systemctl restart xrdp
```

If the port listens and ufw allows it but the connection still times out, your hosting provider blocks 3389.

**Grey or black screen after login** — an old session is still running:

```bash
sudo pkill -u USER -f xfce4-session
```

**Session dies immediately** — `sudo journalctl -u xrdp -u xrdp-sesman -n 100 --no-pager`, plus `/var/log/xrdp-sesman.log` and `~/.xorgxrdp.10.log`.

**DreamBot download failed** — Cloudflare blocked the VM. Fetch it manually:

```bash
wget -O ~/DreamBot/DBLauncher.jar https://downloads.dreambot.org/launcher/Launcher.jar
```

**Locked yourself out** — use the provider's console: `sudo fail2ban-client set sshd unbanip YOUR.IP`

## License

MIT
