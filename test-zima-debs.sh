#!/usr/bin/env bash
# Test the packages in a fresh disposable Debian/Ubuntu container.
set -Eeuo pipefail
TARGET="${1:-debian:trixie}"
DIR="${2:-${PWD}/zima-debs}"
case "$TARGET" in
  debian:trixie) suffix='+deb13' ;;
  ubuntu:26.04) suffix='+ubuntu26.04' ;;
  *) echo 'Podporované obrazy: debian:trixie, ubuntu:26.04' >&2; exit 2 ;;
esac
[[ -d "$DIR" ]] || { echo "Složka neexistuje: $DIR" >&2; exit 1; }
DIR=$(realpath "$DIR")
engine=''
for e in podman docker; do if command -v "$e" >/dev/null; then engine="$e"; break; fi; done
[[ -n "$engine" ]] || { echo 'Chybí podman nebo docker.' >&2; exit 1; }
shopt -s nullglob
files=( "$DIR"/*"$suffix"*.deb )
((${#files[@]} >= 6)) || { echo "Nejsou zde všechny balíčky pro $TARGET" >&2; exit 1; }
"$engine" run --rm --network=bridge -v "$DIR:/packages:ro" "$TARGET" /bin/bash -ceu '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  case "$(. /etc/os-release; echo "$ID:$VERSION_ID")" in
    debian:13*) pattern="*+deb13*.deb" ;;
    ubuntu:26.04) pattern="*+ubuntu26.04*.deb" ;;
    *) echo "Neznámá distribuce" >&2; exit 1 ;;
  esac
  shopt -s nullglob
  packages=(/packages/$pattern)
  ((${#packages[@]} >= 6))
  apt-get install -y --no-install-recommends "${packages[@]}"
  test -r /usr/lib/zima-cad/config/config.ini
  test -x /usr/lib/zima-cad/bin/zima-cad-cpp
  test -x /usr/lib/zima-cad/bin/zima-cad-cli
  test -x /usr/lib/zima-cad/bin/zima-cad-update
  ldd /usr/lib/zima-cad/bin/zima-cad-cpp | tee /tmp/zima-ldd.txt
  ! grep -q "not found" /tmp/zima-ldd.txt
  QT_QPA_PLATFORM=offscreen zima-cad-cli --help
  dpkg-query -W "zima-cad*"
  echo "Balíčky se nainstalovaly a CLI se spustilo. GUI je nutné otestovat na desktopu."
'
