"""Packages the Linux release: python3 -I tools/package_linux.py <binary> <out.tar.gz>.

One tarball for every distro: fastcord/ holds the binary (glibc 2.17+, X11/EGL/fontconfig/ALSA opened at
run time), a desktop entry, the icon and install.sh, which installs for the current user (or system-wide
as root) without a package manager. Built on any OS: file modes are set here, not taken from the disk.
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

def main():
    binary, out = sys.argv[1], sys.argv[2]
    now = int(time.time())
    files = [
        ("fastcord", open(binary, "rb").read(), 0o755),
        ("fastcord.desktop", DESKTOP.encode(), 0o644),
        ("fastcord.png", open("assets/fastcord.png", "rb").read(), 0o644),
        ("install.sh", INSTALL.encode(), 0o755),
        ("README.txt", README.encode(), 0o644),
    ]
    with tarfile.open(out, "w:gz") as tar:
        d = tarfile.TarInfo("fastcord")
        d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o755, now
        tar.addfile(d)
        for name, data, mode in files:
            info = tarfile.TarInfo("fastcord/" + name)
            info.size, info.mode, info.mtime = len(data), mode, now
            tar.addfile(info, io.BytesIO(data))
    print(out)

main()
