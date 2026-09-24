#!/bin/sh
# Installs the latest Zimacs release under ~/.local and registers it with the
# desktop, so it appears in the applications menu alongside everything else.
#
#   curl -fsSL https://raw.githubusercontent.com/IWhitebird/Zimacs/master/scripts/install.sh | sh
#
# Set PREFIX to install somewhere other than ~/.local.
set -eu
exec </dev/null

REPO="IWhitebird/Zimacs"
PREFIX="${PREFIX:-$HOME/.local}"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux. See https://github.com/$REPO/releases"

case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  *) die "no prebuilt binary for $(uname -m). Build from source: https://github.com/$REPO" ;;
esac

for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
  sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$tag" ] || die "could not work out the latest release"

name="zimacs-$tag-linux-$arch"
url="https://github.com/$REPO/releases/download/$tag/$name.tar.gz"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "Downloading Zimacs $tag (about 4.5 MB)"
curl -fL --progress-bar \
  --connect-timeout 20 --max-time 900 --retry 3 --retry-delay 2 \
  "$url" -o "$tmp/$name.tar.gz" || die "download failed: $url"

# Verify against the checksum published next to the tarball. This catches a
# truncated download; it is not a signature and does not prove authorship.
if curl -fsSL --connect-timeout 20 --max-time 60 \
  "$url.sha256" -o "$tmp/$name.tar.gz.sha256" 2>/dev/null &&
  command -v sha256sum >/dev/null 2>&1; then
  (cd "$tmp" && sha256sum -c "$name.tar.gz.sha256" >/dev/null 2>&1) ||
    die "checksum did not match, refusing to install"
  say "Checksum verified"
fi

say "Unpacking"
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
src="$tmp/$name"
[ -x "$src/Zimacs" ] || die "the archive did not contain the binary"

libdir="$PREFIX/share/zimacs"
bindir="$PREFIX/bin"
appdir="$PREFIX/share/applications"
icondir="$PREFIX/share/icons/hicolor/256x256/apps"
mkdir -p "$libdir" "$bindir" "$appdir" "$icondir"

say "Installing to $PREFIX"
install -m 755 "$src/Zimacs" "$libdir/Zimacs"
if [ -f "$src/zimacs.png" ]; then
  install -m 644 "$src/zimacs.png" "$icondir/zimacs.png"
fi
ln -sf "$libdir/Zimacs" "$bindir/zimacs"

cat >"$appdir/zimacs.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=Zimacs
GenericName=Text Editor
Comment=A small, fast text editor written in Zig
Exec=$libdir/Zimacs %F
TryExec=$libdir/Zimacs
Icon=zimacs
Terminal=false
StartupNotify=true
Categories=Utility;TextEditor;
MimeType=text/plain;text/markdown;text/x-csrc;text/x-chdr;text/x-python;application/json;
Keywords=text;editor;code;
DESKTOP
chmod 644 "$appdir/zimacs.desktop"

# Without these the menu can take a login to notice the new entry. They
# scan every theme on the machine, so they are the slowest step here.
say "Registering it with the desktop"
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$appdir" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 &&
  gtk-update-icon-cache -qtf "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true

say ""
say "Zimacs $tag is installed."
say "  binary        $bindir/zimacs"
say "  applications  $appdir/zimacs.desktop"
say ""
say "It should now show up in your applications menu. To remove it:"
say "  rm -rf $libdir $bindir/zimacs $appdir/zimacs.desktop $icondir/zimacs.png"

case ":${PATH:-}:" in
*":$bindir:"*) ;;
*)
  say ""
  say "$bindir is not on your PATH. Add it with:"
  say "  echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.profile"
  ;;
esac
