pkgname=nimzo
pkgver=0.9.3
pkgrel=1
pkgdesc='Wayland compositor with configurable window zones'
arch=('x86_64')
url='https://github.com/rmt/nimzo'
license=('GPL-3.0-or-later' 'MIT')
depends=('cairo' 'glib2' 'glibc' 'harfbuzz' 'libinput' 'libxcb' 'libxkbcommon'
         'pango' 'pcre' 'wayland' 'wlroots0.20' 'xcb-util-wm')
makedepends=('mesa' 'nim' 'wayland-protocols')
optdepends=('foot: default terminal emulator'
            'xorg-xwayland: run X11 applications')
source=("$pkgname-$pkgver-github.tar.gz::$url/archive/refs/tags/$pkgver.tar.gz")
sha256sums=('3591746ac1180be751d18d7f264e7f6d930258631ccaf4dcceb8f4d45f404908')

build() {
  cd "$pkgname-$pkgver"
  local compiler banner version
  local version_pattern='^Nim Compiler Version ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$)'
  if ! compiler=$(command -v nim) || ! banner=$("$compiler" --version) ||
      [[ ! $banner =~ $version_pattern ]]; then
    printf 'Could not determine the Nim version. Install Nim or select a compiler with choosenim.\n' >&2
    return 1
  fi
  version=${BASH_REMATCH[1]}
  if (( $(vercmp "$version" 2.2.0) < 0 )); then
    printf 'Nim 2.2.0 or later is required; found %s (%s).\n' "$version" "$compiler" >&2
    return 1
  fi
  NIMZO_XWAYLAND=1 "$compiler" c --nimcache:"$srcdir/nimcache" --out:nimzo nimzo.nim
}

check() {
  cd "$pkgname-$pkgver"
  ./nimzo -C -c config.example
}

package() {
  cd "$pkgname-$pkgver"
  install -Dm755 nimzo "$pkgdir/usr/bin/nimzo"
  install -Dm644 nimzo.1 "$pkgdir/usr/share/man/man1/nimzo.1"
  install -Dm644 nimzo.desktop "$pkgdir/usr/share/wayland-sessions/nimzo.desktop"
  install -Dm644 config.example "$pkgdir/usr/share/doc/$pkgname/config.example"
  install -Dm644 -t "$pkgdir/usr/share/licenses/$pkgname" LICENSE LICENSE.dwm LICENSE.sway protocols/*.xml
}
