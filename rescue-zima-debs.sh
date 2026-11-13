#!/usr/bin/env bash
# Repackage existing staged ZIMA-CAD files WITHOUT running git, cmake or compiler.
set -Eeuo pipefail
TARGET='debian:trixie'
WORKDIR="${PWD}/.zima-deb-work"
OUTDIR="${PWD}/zima-debs"
usage() {
  cat <<'EOT'
Použití: ./rescue-zima-debs.sh [--target debian:trixie|ubuntu:26.04] [--workdir DIR] [--output DIR]
Spusť v adresáři zima-cad-packaging po selhání dpkg-deb.
Soubory musí již existovat v .zima-deb-work/packages/*/DEBIAN/control.
Neprovádí žádný překlad ani nestahuje zdrojové kódy.
EOT
}
while (($#)); do
  case "$1" in
    --target|--workdir|--output)
      (($# >= 2)) || { echo "Chybí hodnota $1" >&2; exit 2; }
      case "$1" in
        --target) TARGET=$2 ;;
        --workdir) WORKDIR=$2 ;;
        --output) OUTDIR=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Neznámá volba: $1" >&2; usage; exit 2 ;;
  esac
done
case "$TARGET" in debian:trixie|ubuntu:26.04) ;; *) echo "Nepodporovaný obraz: $TARGET" >&2; exit 2 ;; esac
[[ -d "$WORKDIR/packages" ]] || { echo "Chybí $WORKDIR/packages – nic k záchraně" >&2; exit 1; }
WORKDIR=$(realpath "$WORKDIR")
mkdir -p "$OUTDIR"
OUTDIR=$(realpath "$OUTDIR")
engine=''
for e in podman docker; do if command -v "$e" >/dev/null; then engine="$e"; break; fi; done
[[ -n "$engine" ]] || { echo 'Chybí podman nebo docker.' >&2; exit 1; }
echo "==> Zachraňuji balíčky z: $WORKDIR/packages"
"$engine" run --rm --network=none \
  -v "$WORKDIR:/work" -v "$OUTDIR:/out" "$TARGET" bash -euo pipefail -c '
    shopt -s nullglob
    controls=(/work/packages/zima-*/DEBIAN/control)
    ((${#controls[@]} == 6)) || { echo "Očekávám 6 control souborů; našel jsem ${#controls[@]}." >&2; exit 1; }
    version=""
    for c in "${controls[@]}"; do
      directory=${c%/control}
      pkg=${directory%/DEBIAN}
      chmod g-s "$directory"
      chmod 0755 "$directory"
      name=$(sed -n "s/^Package: //p" "$c")
      ver=$(sed -n "s/^Version: //p" "$c")
      arch=$(sed -n "s/^Architecture: //p" "$c")
      [[ -n "$name" && -n "$ver" && -n "$arch" ]] || { echo "Chybný control: $c" >&2; exit 1; }
      if [[ -n "$version" && "$version" != "$ver" ]]; then
        echo "Nekonzistentní verze mezi balíčky: $version != $ver" >&2; exit 1
      fi
      version="$ver"
      dpkg-deb --root-owner-group -Zxz -z6 --build "$pkg" "/out/${name}_${ver}_${arch}.deb"
    done
    cd /out
    files=(./*_${version}_*.deb)
    ((${#files[@]} == 6)) || { echo "Očekáváno 6 .deb, nalezeno ${#files[@]}" >&2; exit 1; }
    sha256sum "${files[@]}" > "SHA256SUMS-$version"
    echo "==> Hotovo:"
    ls -lh "${files[@]}"
    echo "==> Kontrolní součet: SHA256SUMS-$version"
  '
