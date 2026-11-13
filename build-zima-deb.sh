#!/usr/bin/env bash
# Experimental ZIMA-CAD Debian/Ubuntu packaging helper.
# Produces: zima-cad, zima-cad-cli, zima-cad-data, zima-cad-materials, zima-cad-library, zima-cad-runtime.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_URL='https://github.com/ZIMA-Engineering/ZIMA-CAD.git'
REF='main'
TARGET='debian:trixie'
WORKDIR="${PWD}/.zima-deb-work"
OUTDIR="${PWD}/zima-debs"
JOBS="${ZIMA_BUILD_JOBS:-4}"
NATIVE=0
INSTALL_DEPS=0
SKIP_SDK=0
CLEAN=0

usage() {
  cat <<'EOF'
Použití: ./build-zima-deb.sh [volby]
  --target debian:trixie     Výchozí: Debian 13 v Podmanu/Dockeru
  --target ubuntu:26.04     Ubuntu 26.04 v Podmanu/Dockeru (ověří se Qt)
  --native                  Sestavit přímo na místním Debianu/Ubuntu
  --install-deps            Instalovat závislosti přes apt (root, nebo sudo)
  --ref REV                 Git větev/tag/commit (výchozí main)
  --jobs N                  Paralelní úlohy (výchozí 4)
  --workdir DIR             Pracovní strom/cache
  --output DIR              Výstupní .deb soubory
  --skip-sdk                Použít již sestavené build/native-sdk/occt-8.0.1
  --clean                   Smazat lokální checkout/build/cache před sestavením
  -h, --help                Tato nápověda

Spuštění na Gentoo bez zásahu do hosta:
  ./build-zima-deb.sh --target debian:trixie --jobs 4

Pozn.: Ubuntu 24.04 a Debian 12 mají příliš staré Qt pro aktuální ZIMA-CAD.
EOF
}
die() { printf 'CHYBA: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null || die "Chybí příkaz: $1"; }
while (($#)); do
  case "$1" in
    --target|--ref|--jobs|--workdir|--output)
      (($# >= 2)) || die "Chybí hodnota parametru $1"
      case "$1" in
        --target) TARGET="$2" ;; --ref) REF="$2" ;; --jobs) JOBS="$2" ;;
        --workdir) WORKDIR="$2" ;; --output) OUTDIR="$2" ;;
      esac; shift 2 ;;
    --native) NATIVE=1; shift ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    --skip-sdk) SKIP_SDK=1; shift ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Neznámý parametr: $1" ;;
  esac
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die '--jobs musí být kladné celé číslo'
[[ "$REF" != -* ]] || die '--ref nesmí začínat pomlčkou'
case "$TARGET" in debian:trixie|ubuntu:26.04) ;; *) ((NATIVE)) || die 'Podporované kontejnery: debian:trixie, ubuntu:26.04' ;; esac
mkdir -p "$WORKDIR" "$OUTDIR"
WORKDIR=$(realpath -m "$WORKDIR")
OUTDIR=$(realpath -m "$OUTDIR")
[[ "$OUTDIR/" != "$WORKDIR/"* ]] || die '--output musí být mimo --workdir'

if (( !NATIVE )); then
  engine=''
  for e in podman docker; do if command -v "$e" >/dev/null; then engine="$e"; break; fi; done
  [[ -n "$engine" ]] || die 'Není k dispozici Podman ani Docker; lze použít --native.'
  self=$(realpath "$0")
  log "Spouštím $TARGET v $engine, zdroj a výstupy budou v $WORKDIR a $OUTDIR"
  envargs=( -e "ZIMA_BUILD_JOBS=$JOBS" -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" )
  "$engine" run --rm --network=bridge "${envargs[@]}" \
    -v "$WORKDIR:/work" -v "$OUTDIR:/out" -v "$self:/usr/local/bin/build-zima-deb.sh:ro" \
    --workdir /work "$TARGET" bash /usr/local/bin/build-zima-deb.sh \
    --native --install-deps --ref "$REF" --jobs "$JOBS" --workdir /work --output /out \
    $( ((SKIP_SDK)) && printf '%s' --skip-sdk || true ) \
    $( ((CLEAN)) && printf '%s' --clean || true )
  exit
fi

[[ -f /etc/os-release ]] || die 'Vyžaduje Debian/Ubuntu.'
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die 'Přímé sestavení je určené pro Debian/Ubuntu.' ;; esac
if ((INSTALL_DEPS)); then
  need apt-get
  apt=( )
  if [[ $(id -u) -ne 0 ]]; then need sudo; apt=(sudo); fi
  log 'Instaluji build závislosti (ne systémovou OCCT).'
  "${apt[@]}" apt-get update
  DEBIAN_FRONTEND=noninteractive "${apt[@]}" apt-get install -y --no-install-recommends \
    ca-certificates git curl build-essential cmake ninja-build pkg-config python3 patchelf \
    dpkg-dev xz-utils libssl-dev libzstd-dev zlib1g-dev nlohmann-json3-dev \
    libfreetype-dev libharfbuzz-dev libsecret-1-dev \
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-webengine-dev \
    qt6-webchannel-dev libqt6svg6-dev qt6-tools-dev
fi
for c in git cmake ninja patchelf dpkg-deb dpkg-query python3 curl sha256sum; do need "$c"; done
if ((CLEAN)); then
  log 'Mažu zdrojový a build strom (výstupní .deb se zachovají)'
  rm -rf -- "$WORKDIR/source" "$WORKDIR/build" "$WORKDIR/packages"
fi

SRC="$WORKDIR/source"
if [[ ! -d "$SRC/.git" ]]; then
  log 'Stahuji ZIMA-CAD z GitHubu'
  git clone --filter=blob:none --recursive "$REPO_URL" "$SRC"
fi
log "Přepínám na revizi $REF"
git -C "$SRC" fetch --depth=1 origin "$REF"
git -C "$SRC" checkout --force --detach FETCH_HEAD
git -C "$SRC" submodule update --init --recursive
COMMIT=$(git -C "$SRC" rev-parse HEAD)
VERSION=$(tr -d '\r\n' < "$SRC/VERSION")
[[ "$VERSION" =~ ^[0-9]{10}$ ]] || die "Neplatný VERSION: $VERSION"
UPSTREAM_VERSION="$VERSION"
case "$ID" in
  debian) VERSION="${VERSION}+deb${VERSION_ID%%.*}" ;;
  ubuntu) VERSION="${VERSION}+ubuntu${VERSION_ID}" ;;
esac
ARCH=$(dpkg --print-architecture)
log "Zdroj: $COMMIT, VERSION=$VERSION, $ID ${VERSION_ID:-?}, arch=$ARCH"

# Debian/Ubuntu Qt gate; do NOT weaken upstream CMake dependency gates.
QT_VER=$(pkg-config --modversion Qt6Core 2>/dev/null || true)
[[ -n "$QT_VER" ]] || die 'Qt6Core neexistuje v pkg-config. Zkontroluj build závislosti.'
python3 - "$QT_VER" <<'PY'
import sys
from itertools import zip_longest
v=tuple(map(int,sys.argv[1].split('.')[:3]))
if v < (6,5):
    raise SystemExit(f'Qt {sys.argv[1]} je staré. Je potřeba Qt >= 6.5 (neobcházet CMake).')
PY
SDK="$SRC/build/native-sdk/occt-8.0.1"
if [[ ! -f "$SDK/share/opencascade/zima-sdk.json" ]]; then
  ((SKIP_SDK)) && die 'SDK nenalezeno; spusť bez --skip-sdk'
  log 'Sestavuji OCCT 8.0.1 s ověřenou projektovou úpravou'
  ZIMA_BUILD_JOBS="$JOBS" bash "$SRC/tools/distribution/build-linux-sdk.sh"
else
  log 'Použiji existující projektové OCCT SDK; CMake ověří jeho patch.'
fi

BUILD="$WORKDIR/build"
mkdir -p "$BUILD"
log 'Konfiguruji CMake (Release, produkční cíle)'
cmake -S "$SRC/cpp" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DZIMA_BUILD_TESTS=OFF \
  -DCMAKE_INSTALL_PREFIX=/usr/lib/zima-cad \
  -DCMAKE_PREFIX_PATH="$SDK" \
  -DOpenCASCADE_DIR="$SDK/lib/cmake/opencascade" \
  -DCMAKE_SKIP_BUILD_RPATH=OFF
log 'Kompiluji GUI, CLI a updater'
cmake --build "$BUILD" --parallel "$JOBS" --target zima-cad-cpp zima-cad-cli zima-cad-update

PKGROOT="$WORKDIR/packages"
rm -rf -- "$PKGROOT"
mkdir -p "$PKGROOT"
for p in zima-cad zima-cad-cli zima-cad-data zima-cad-materials zima-cad-library zima-cad-runtime; do
  mkdir -p "$PKGROOT/$p/DEBIAN" "$PKGROOT/$p/usr/share/doc/$p"
  # SGID inherited from host bind-mount breaks dpkg-deb control validation.
  chmod g-s "$PKGROOT/$p/DEBIAN"
  chmod 0755 "$PKGROOT/$p/DEBIAN"
  install -m 0644 "$SRC/LICENSE" "$PKGROOT/$p/usr/share/doc/$p/copyright"
done
APP="$PKGROOT/zima-cad"
CLI="$PKGROOT/zima-cad-cli"
DATA="$PKGROOT/zima-cad-data"
LIBRARY="$PKGROOT/zima-cad-library"
MATERIALS="$PKGROOT/zima-cad-materials"
RUNTIME="$PKGROOT/zima-cad-runtime"
STAGE="$PKGROOT/_install"
mkdir -p "$STAGE"
DESTDIR="$STAGE" cmake --install "$BUILD" --prefix /usr/lib/zima-cad
for binary in zima-cad-cpp zima-cad-update; do
  install -Dm755 "$STAGE/usr/lib/zima-cad/bin/$binary" "$APP/usr/lib/zima-cad/bin/$binary"
done
install -Dm755 "$STAGE/usr/lib/zima-cad/bin/zima-cad-cli" "$CLI/usr/lib/zima-cad/bin/zima-cad-cli"

# Asset layout follows C++ settings: config.ini plus relative config/{materials,templates,lib,...}.
mkdir -p "$DATA/usr/lib/zima-cad" "$LIBRARY/usr/lib/zima-cad/config" "$MATERIALS/usr/lib/zima-cad/config"
cp -a "$SRC/config" "$DATA/usr/lib/zima-cad/"
[[ -f "$DATA/usr/lib/zima-cad/config/config.ini" ]] || die 'Nenalezena tovární config/config.ini'
if [[ -d "$DATA/usr/lib/zima-cad/config/lib" ]]; then
  mv "$DATA/usr/lib/zima-cad/config/lib" "$LIBRARY/usr/lib/zima-cad/config/lib"
fi
if [[ -d "$DATA/usr/lib/zima-cad/config/materials" ]]; then
  mv "$DATA/usr/lib/zima-cad/config/materials" "$MATERIALS/usr/lib/zima-cad/config/materials"
fi
if [[ -d "$SRC/resources" ]]; then
  cp -a "$SRC/resources" "$DATA/usr/lib/zima-cad/"
fi
# Current unversioned non-portable layout looks for config/config.ini relative to exe dir.
mkdir -p "$DATA/usr/lib/zima-cad/bin"
ln -s ../config "$DATA/usr/lib/zima-cad/bin/config"
if [[ -d "$DATA/usr/lib/zima-cad/resources" ]]; then
  ln -s ../resources "$DATA/usr/lib/zima-cad/bin/resources"
fi
install -Dm644 "$SRC/cpp/app/linux/zima-cad.desktop" "$APP/usr/share/applications/zima-cad.desktop"
sed -i 's/^Exec=.*/Exec=zima-cad %F/' "$APP/usr/share/applications/zima-cad.desktop"
install -Dm644 "$SRC/resources/branding/app-icon.svg" \
  "$APP/usr/share/icons/hicolor/scalable/apps/zima-cad.svg"

# Bundle only the uniquely patched OCCT; never vendor distro Qt/OpenSSL libraries.
mkdir -p "$RUNTIME/usr/lib/zima-cad/occt"
shopt -s nullglob
sos=( "$SDK"/lib/*.so* )
((${#sos[@]})) || die 'OCCT SDK neobsahuje sdílené .so knihovny; nelze vytvořit runtime .deb'
cp -a -- "${sos[@]}" "$RUNTIME/usr/lib/zima-cad/occt/"
install -Dm644 "$SDK/share/opencascade/zima-sdk.json" \
  "$RUNTIME/usr/share/doc/zima-cad-runtime/zima-sdk.json"

# Relative RPATH resolves the private OCCT lib beside the application without polluting LD_LIBRARY_PATH.
for bin in "$APP/usr/lib/zima-cad/bin/"* "$CLI/usr/lib/zima-cad/bin/"*; do
  patchelf --set-rpath '$ORIGIN/../occt' "$bin"
done
find "$RUNTIME/usr/lib/zima-cad/occt" -maxdepth 1 -type f -name '*.so*' -print0 | \
  while IFS= read -r -d '' so; do patchelf --set-rpath '$ORIGIN' "$so"; done

# Wrapper: default project directory and writable per-user config.ini.
# NOTE: documents launched directly by path can override the startup directory upstream.
install -d "$APP/usr/bin" "$CLI/usr/bin"
cat > "$APP/usr/bin/zima-cad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
workspace="${ZIMA_CAD_WORKSPACE:-$HOME/ZIMA-CAD}"
mkdir -p "$workspace"
if [[ ! -e "$workspace/config.ini" ]]; then
  printf '[Updates]\nCheckAtStartup=false\n' > "$workspace/config.ini"
fi
exec /usr/lib/zima-cad/bin/zima-cad-cpp --working-directory "$workspace" "$@"
EOF
cat > "$CLI/usr/bin/zima-cad-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/zima-cad/bin/zima-cad-cli "$@"
EOF
chmod 755 "$APP/usr/bin/zima-cad" "$CLI/usr/bin/zima-cad-cli"

# Extract system package dependency ownership from ALL linked ELF files.
# Third-party Qt plugins use their regular distro packages. Private OCCT is excluded.
compute_deps() {
  python3 - "$SDK/lib" "$@" <<'PY'
import os, pathlib, re, subprocess, sys
sdk=pathlib.Path(sys.argv[1]).resolve()
elfs=[pathlib.Path(x) for x in sys.argv[2:]]
packages=set()
missing=[]
for elf in elfs:
    run=subprocess.run(['ldd',str(elf)],env={**os.environ,'LD_LIBRARY_PATH':str(sdk)},text=True,capture_output=True)
    if run.returncode:
        raise SystemExit(f'ldd failed for {elf}: {run.stderr}')
    for line in run.stdout.splitlines():
        if '=> not found' in line:
            missing.append(f'{elf.name}: {line.strip()}')
            continue
        mat=re.search(r'(?:=>\s*)?(/\S+)(?=\s*\()',line)
        if not mat: continue
        path=pathlib.Path(mat.group(1)).resolve()
        if path.is_relative_to(sdk): continue
        q=subprocess.run(['dpkg-query','-S',str(path)],capture_output=True,text=True)
        if q.returncode:
            # Some loader-built paths (e.g. glibc linker) have no owning package mapping.
            continue
        owner=q.stdout.splitlines()[0].split(': ',1)[0].split(':',1)[0]
        if owner: packages.add(owner)
if missing: raise SystemExit('Chybějící runtime knihovny:\n'+'\n'.join(missing))
print(', '.join(sorted(packages)))
PY
}
mapfile -d '' RT_ELFS < <(find "$RUNTIME/usr/lib/zima-cad/occt" -maxdepth 1 -type f -name '*.so*' -print0)
RT_DEP=$(compute_deps "${RT_ELFS[@]}")
APP_DEP=$(compute_deps "$APP/usr/lib/zima-cad/bin/zima-cad-cpp" "$APP/usr/lib/zima-cad/bin/zima-cad-update")
CLI_DEP=$(compute_deps "$CLI/usr/lib/zima-cad/bin/zima-cad-cli")

# Supplemental Qt runtime plugin (not always a DT_NEEDED dependency).
# The library packages bring their transitive QtWebEngine runtime dependencies.
if dpkg-query -W -f='${Status}' qt6-qpa-plugins 2>/dev/null | grep -q 'install ok installed'; then
  APP_DEP="${APP_DEP:+$APP_DEP, }qt6-qpa-plugins"
  CLI_DEP="${CLI_DEP:+$CLI_DEP, }qt6-qpa-plugins"
fi

control() {
  local name="$1" arch="$2" depends="$3" recommends="$4" desc="$5"
  {
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$name" "$VERSION" "$arch"
    printf 'Maintainer: Unofficial ZIMA-CAD packager <noreply@localhost>\n'
    printf 'Section: graphics\nPriority: optional\nHomepage: https://github.com/ZIMA-Engineering/ZIMA-CAD\n'
    [[ -z "$depends" ]] || printf 'Depends: %s\n' "$depends"
    [[ -z "$recommends" ]] || printf 'Recommends: %s\n' "$recommends"
    printf 'Description: %s\n Unofficial experimental package from Git commit %s\n' "$desc" "$COMMIT"
  } > "$PKGROOT/$name/DEBIAN/control"
}
control zima-cad "$ARCH" "zima-cad-data (= $VERSION), zima-cad-runtime (= $VERSION)${APP_DEP:+, $APP_DEP}" \
  "zima-cad-library (= $VERSION), zima-cad-materials (= $VERSION), zima-cad-cli (= $VERSION)" 'ZIMA-CAD parametric 3D CAD graphical application'
control zima-cad-cli "$ARCH" "zima-cad-data (= $VERSION), zima-cad-runtime (= $VERSION)${CLI_DEP:+, $CLI_DEP}" '' \
  'ZIMA-CAD command-line interface'
control zima-cad-materials all "zima-cad-data (= $VERSION)" '' 'ZIMA-CAD factory material specifications'
control zima-cad-runtime "$ARCH" "${RT_DEP}" '' 'ZIMA-CAD patched OpenCASCADE 8.0.1 runtime libraries'
control zima-cad-data all '' '' 'ZIMA-CAD factory configuration, templates, languages and resources'
control zima-cad-library all 'zima-cad-data (= '"$VERSION"')' '' 'ZIMA-CAD native model and engineering libraries'

log 'Balím jednotlivé součásti (.deb)'
for p in zima-cad zima-cad-cli zima-cad-data zima-cad-materials zima-cad-library zima-cad-runtime; do
  pkg="$PKGROOT/$p"
  (cd "$pkg" && find usr -type f -print0 | sort -z | xargs -0 -r md5sum > DEBIAN/md5sums)
  targetarch="$ARCH"; [[ "$p" == zima-cad-data || "$p" == zima-cad-materials || "$p" == zima-cad-library ]] && targetarch=all
  dpkg-deb --root-owner-group -Zxz -z6 --build "$pkg" "$OUTDIR/${p}_${VERSION}_${targetarch}.deb"
done
(cd "$OUTDIR" && sha256sum ./*_"$VERSION"_*.deb > "SHA256SUMS-$VERSION")
log 'Hotovo:'
ls -lh "$OUTDIR"/*_"$VERSION"_*.deb
log "SHA256: $OUTDIR/SHA256SUMS-$VERSION"
# When built in a privileged container, return ownership to the invoker if possible.
if [[ $(id -u) -eq 0 && -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  chown "${HOST_UID}:${HOST_GID}" "$OUTDIR"/*_"$VERSION"_*.deb "$OUTDIR/SHA256SUMS-$VERSION" || true
fi
