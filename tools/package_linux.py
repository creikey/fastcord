"""Packages the Linux release: python3 -I tools/package_linux.py <binary> <out.tar.gz> [server].

One tarball for every distro: fastcord/ holds the binary (glibc 2.17+, X11/EGL/fontconfig/ALSA opened at
run time), a desktop entry, the icon and install.sh, which installs for the current user (or system-wide
as root) without a package manager. With `server`, fastcord-server/ holds the same binary (-serve opens no
display library) with a systemd unit and a README, for a headless machine. Built on any OS: file modes
are set here, not taken from the disk.
"""
import io, sys, tarfile, time

DESKTOP = """[Desktop Entry]
Type=Application
Name=Fastcord
GenericName=Chat
Comment=A fast, native Discord client
Exec=fastcord %U
Icon=fastcord
Terminal=false
Categories=Network;InstantMessaging;Chat;
MimeType=x-scheme-handler/fc;x-scheme-handler/discord;
StartupWMClass=fastcord
"""

INSTALL = """#!/bin/sh
# Installs Fastcord for this user (~/.local), or for everyone when run as root (/usr/local).
set -e
here=$(cd "$(dirname "$0")" && pwd)
if [ "$(id -u)" = 0 ]; then prefix=/usr/local; else prefix="$HOME/.local"; fi
mkdir -p "$prefix/bin" "$prefix/share/applications" "$prefix/share/icons/hicolor/256x256/apps"
install -m 755 "$here/fastcord" "$prefix/bin/fastcord"
install -m 644 "$here/fastcord.png" "$prefix/share/icons/hicolor/256x256/apps/fastcord.png"
sed "s|^Exec=fastcord|Exec=$prefix/bin/fastcord|" "$here/fastcord.desktop" > "$prefix/share/applications/fastcord.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$prefix/share/applications" 2>/dev/null || true
# fc:// links open fastcord; discord:// ones only when no other app (the official client) has them
if command -v xdg-mime >/dev/null 2>&1; then
  xdg-mime default fastcord.desktop x-scheme-handler/fc || true
  [ -z "$(xdg-mime query default x-scheme-handler/discord 2>/dev/null)" ] && xdg-mime default fastcord.desktop x-scheme-handler/discord || true
fi
echo "Installed $prefix/bin/fastcord (open Fastcord from your app menu)"
"""

README = """Fastcord for Linux (x86_64)

Run it in place:   ./fastcord
Install it:        ./install.sh        (your user; as root: system-wide in /usr/local)

Works on any distribution with glibc 2.17 or newer (2014+) and an X11 or Wayland desktop (through
XWayland). Uses OpenGL 3.3 through EGL, fontconfig for fonts and ALSA (PipeWire / PulseAudio) for voice,
all loaded at run time. Settings and the login token live in ${XDG_DATA_HOME:-~/.local/share}/fastcord.
"""

UNIT = """[Unit]
Description=Fastcord server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/fastcord -serve:/var/lib/fastcord/server.db -port:4433
Restart=on-failure
RestartSec=5
DynamicUser=yes
StateDirectory=fastcord

[Install]
WantedBy=multi-user.target
"""

SERVER_README = """Fastcord server for Linux (x86_64)

A self-hosted Fastcord server: one SQLite file, TLS on TCP port 4433. Needs no display, no Discord and
no account; members join from the Fastcord app with an fc:// invite and their own key.

Try it:            ./fastcord -serve:myserver.db          (prints the invites; Ctrl-C stops it)
Run it as a service (as root):
    install -m 755 fastcord /usr/local/bin/fastcord
    install -m 644 fastcord-server.service /etc/systemd/system/
    systemctl enable --now fastcord-server
    journalctl -u fastcord-server              (the invites; also in /var/lib/fastcord/server.db.log)

Open or forward TCP and UDP 4433 (UDP carries voice). Join first with the one-use owner invite to own
the server, then set its public address or DNS name in Server Settings > Network so invites carry it.
The whole server is the one file. It backs itself up daily to /var/lib/fastcord/server-backups (the last
7, each checked; -backups:<dir> in ExecStart for another disk), and the owner can back up and restore
from Server Settings. To update, replace the binary and restart the service.
"""

def main():
    binary, out = sys.argv[1], sys.argv[2]
    server = sys.argv[3:] == ["server"]
    now = int(time.time())
    top = "fastcord-server" if server else "fastcord"
    files = [("fastcord", open(binary, "rb").read(), 0o755)]
    if server:
        files += [
            ("fastcord-server.service", UNIT.encode(), 0o644),
            ("README.txt", SERVER_README.encode(), 0o644),
        ]
    else:
        files += [
            ("fastcord.desktop", DESKTOP.encode(), 0o644),
            ("fastcord.png", open("assets/fastcord.png", "rb").read(), 0o644),
            ("install.sh", INSTALL.encode(), 0o755),
            ("README.txt", README.encode(), 0o644),
        ]
    with tarfile.open(out, "w:gz") as tar:
        d = tarfile.TarInfo(top)
        d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, now
        tar.addfile(d)
        for name, data, mode in files:
            info = tarfile.TarInfo(top + "/" + name)
            info.size, info.mode, info.mtime = len(data), mode, now
            tar.addfile(info, io.BytesIO(data))
    print(out)

main()
