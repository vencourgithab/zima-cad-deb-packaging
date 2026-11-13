# ZIMA-CAD → Debian / Ubuntu `.deb` balíčky (experimentální)

Balíčkovací skript pro veřejný upstream [ZIMA-Engineering/ZIMA-CAD](https://github.com/ZIMA-Engineering/ZIMA-CAD). Cílem je vytvořit instalovatelné, samostatně upgradovatelné balíky bez kopírování běžných systémových Qt knihoven.

**Stav:** Skript má kontrolovanou syntaxi a `--help`, ale plné sestavení a grafický smoke test nebyly v prostředí autora tohoto skriptu provedeny (nemá síťový přístup do GitHubu a požadovaný SDK). Nejde o oficiální balíčky projektu ani o potvrzenou podporu Linuxu upstreamem. Aktuální upstream výslovně vyžaduje vlastní OCCT 8.0.1 s patchí a odlišuje linuxové testování od již ověřených windowsových release.

## Rychlé použití (z Gentoo, Linuxu s Podmanem/Dockerem)

```bash
chmod +x build-zima-deb.sh
./build-zima-deb.sh --target debian:trixie --jobs 4
# alternativně:
./build-zima-deb.sh --target ubuntu:26.04 --jobs 4
```

Výsledné soubory najdete v `./zima-debs/`. Zdroj a přeložené objekty zůstanou v `./.zima-deb-work/` pro další běh. Na jinou revizi lze přepnout `--ref TAG_NEBO_COMMIT`; pro úplně nový pokus `--clean`. Doporučuji alespoň několik desítek GB místa a odpovídající RAM: zdroj, OCCT build, C++ objekty, velká knihovna a `.deb` mohou zabrat hodně místa.

Na již připraveném Debianu / Ubuntu můžete použít:

```bash
./build-zima-deb.sh --native --install-deps --jobs 4
```

`--native --install-deps` spouští `apt-get` (použije `sudo`, není-li root). Režim kontejneru instaluje build závislosti *uvnitř kontejneru*. Místní Gentoo nezmění. Nepouštějte cizí build skripty s důvěrnými či pracovními daty namountovanými do kontejneru.

## Co je v balíčcích

| Balíček | Obsah |
| --- | --- |
| `zima-cad` | `/usr/bin/zima-cad`, GUI, update helper, `.desktop`, ikona |
| `zima-cad-cli` | `/usr/bin/zima-cad-cli`, CLI |
| `zima-cad-data` | `config.ini`, šablony, formáty, lokalizace, symboly, resources |
| `zima-cad-materials` | `config/materials/` (pokud je ve zdroji) |
| `zima-cad-library` | `config/lib/` — tovární CAD knihovny |
| `zima-cad-runtime` | vlastní patched OCCT 8.0.1 `.so` bez soukromých kopií Qt/OpenSSL |

Instalované runtime cesty jsou pod `/usr/lib/zima-cad`; desktopová integrace je v `/usr/share`. `zima-cad` doporučuje (`Recommends`) tovární knihovny, materiály a CLI. Žádný balíček nezapisuje do domovského adresáře během instalace.

Každý balíček nese vydání z `VERSION`, doplněné o distribuční příponu (např. `+deb13`, `+ubuntu26.04`). Balíčky tvořené v jednom kontejneru mají stejnou identitu a závisí na odpovídajících přesných verzích vlastních částí. Ostatní runtime závislosti jsou odvozeny ze skutečně nalinkovaných systémových knihoven cílového systému.

## Instalace a testování

Na **stejné verzi distribuce**, pro kterou bylo `.deb` sestaveno:

```bash
cd zima-debs
sha256sum -c SHA256SUMS-*
sudo apt install ./*.deb
zima-cad-cli --help
zima-cad
```

Nezávislý instalační a CLI smoke test v čistém kontejneru:

```bash
./test-zima-debs.sh debian:trixie ./zima-debs
./test-zima-debs.sh ubuntu:26.04 ./zima-debs
```

Pro prohlídku obsahu:

```bash
for deb in ./*.deb; do
  echo "=== $deb ==="
  dpkg-deb -I "$deb" | head -25
  dpkg-deb -c "$deb" | head -25
 done
```

Skript nemění upstream zdroj, nesnižuje závislosti Qt/OCCT, nevypíná kontrolu patchované OCCT. Pro pravidelnou distribuci je potřeba navíc provést `ctest` nativních testů, GUI pod X11 a Wayland, import/export a ověření na čisté instalaci (ideálně v CI).

## Důležité limity současného návrhu

1. **Uživatelská konfigurace:** Oficiální Linux instalační systém ZIMA-CAD ještě nemá běžnou podporu XDG config pro systémové `.deb`. Spouštěč proto při prvním startu vytvoří `~/ZIMA-CAD/config.ini`, pokud neexistuje, a jako výchozí pracovní adresář použije `~/ZIMA-CAD` (lze přesměrovat proměnnou `ZIMA_CAD_WORKSPACE`). Tovární soubory zůstanou jen pro čtení pod `/usr/lib/zima-cad/config` a nepřepisují se upgradem. Při přímém otevření `.prtz` z jiné složky může upstream přepnout pracovní složku a uložit nastavení neúspěšně. Produkční řešení vyžaduje malou změnu upstreamu, aby osobní konfigurace byla nezávislá na adresáři otevřeného projektu.
2. **Aktualizace:** První vytvořená uživatelská `config.ini` vypíná upstream automatický kontrolní mechanismus (`CheckAtStartup=false`), protože `.deb` se má aktualizovat přes APT/dpkg, nikoli přes portable updater. Má-li uživatel vlastní config.ini, skript ho z bezpečnostních důvodů nemění.
3. **Závislosti:** Generování seznamu `Depends` ze systémových knihoven pomocí `ldd` je zatím experimentální. Balíčky jsou určeny výhradně pro systém, na kterém byly sestaveny, nebo kompatibilní obraz **téže** distribuční verze. Doplňkově načítané Qt pluginy, hardwarové GPU ovladače a další nepřímé závislosti vyžadují samostatný validační test; balíčky nejsou univerzální pro jiné Debian/Ubuntu verze.
4. **OCCT:** `zima-cad-runtime` obsahuje soukromou patched OCCT SDK. Před veřejným publikováním je nutné doplnit všechny přesné licenční texty a third-party notices, případně začlenit projekt do standardního Debian zdrojového balíku (`debian/`, `dpkg-buildpackage`) a ověřit reproducibilitu.
5. **Velikost a vydávání:** Plné factory modely mohou mít stovky MB. Včas rozdělte modelové balíky podle obsahu a zvažte `apt` repozitář, podpis, `lintian`, izolované buildy, testy upgrade/rollback a distribuci přes GitHub Actions.

## Zdroje upstreamu

- https://github.com/ZIMA-Engineering/ZIMA-CAD
- https://github.com/ZIMA-Engineering/ZIMA-CAD/blob/main/doc/LINUX_RELEASE_HANDOFF.md
- https://github.com/ZIMA-Engineering/ZIMA-CAD/blob/main/tools/distribution/build-linux-sdk.sh
- https://github.com/ZIMA-Engineering/ZIMA-CAD/blob/main/cpp/CMakeLists.txt
