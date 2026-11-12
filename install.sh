#!/usr/bin/env bash
# install.sh — gefuehrte Installation des Sammel-Patches (turbo2+turbo3+k3v8+Kinetic+Multinode)
#
#   bash install.sh                      Strata-Baum wird automatisch gefunden
#   bash install.sh <strata-ordner>      oder explizit angeben
#   bash install.sh --check-only         nur pruefen, nichts aendern
#   bash install.sh --no-build           patchen, aber nicht bauen
#   bash install.sh --revert             Patch zuruecknehmen
#   bash install.sh --status             Baum anzeigen: Stand, Patch drin oder nicht
#   bash install.sh --force-clean        Ueberreste fremder Dateien ohne Rueckfrage loeschen
#
# Das Skript erkennt von selbst:
#   - ob der Patch schon drauf liegt   -> nichts zu tun
#   - Ueberreste alter Turbo-/Kinetic-Patches ("already exists in working directory")
#   - alte Einzel-Patches aus pott/strata_patch, die noch angewandt sind
#   - eine laufende Engine, die "Text file busy" verursacht
#   - CUDA-Compiler und GPU-Architektur fuer den Notfall-Bau von Hand
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/strata_engine/strata_engine_all.patch"
OLD_REPO_HINT="(cd <patch-Ordner> && bash apply_patch.sh revert strata)"
NEW_FILES=(
  include/strata/kernels/kv_turbo.hpp include/strata/kernels/kv_turbo3.hpp
  include/strata/kernels/kv_k3v8.hpp include/strata/core/remote_stage.hpp
  include/strata/spec/suffix_index.hpp
  src/kernels/cuda/kv_turbo.cu src/kernels/cuda/kv_turbo3.cu
  src/kernels/kv_turbo_parity.cpp src/core/remote_stage.cpp
  src/spec/suffix_index.cpp src/spec/suffix_index_test.cpp
)
PROBE='turbo2|turbo3|k3v8|remote-stage|stage-listen|stage-layers|stage-allow'
EXPECT_FILES=36

MODE="install"; DIR_ARG=""; FORCE_CLEAN=0
for a in "$@"; do
  case "$a" in
    --check-only) MODE="check" ;;
    --no-build)   MODE="no-build" ;;
    --revert)     MODE="revert" ;;
    --status)     MODE="status" ;;
    --force-clean) FORCE_CLEAN=1 ;;
    -h|--help)    sed -n '2,24p' "$0"; exit 0 ;;
    -*)           echo "Unbekannte Option: $a"; sed -n '2,24p' "$0"; exit 2 ;;
    *)            DIR_ARG="$a" ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFEHLER\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mACHTUNG\033[0m %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }

[ -f "$PATCH" ] || { bad "Patch-Datei fehlt: $PATCH"; exit 2; }

# ---------- 1) Baum finden ----------
looks_like_strata() { [ -f "$1/CMakeLists.txt" ] && grep -q "project(strata VERSION" "$1/CMakeLists.txt"; }
find_dir() {
  local c=(. .. ./strata ./Strata ../strata ../Strata "$HOME/models/strata" "$HOME/models/Strata" "$HOME/Machen/strata" "$HOME/Machen/Strata")
  for d in "${c[@]}"; do looks_like_strata "$d" && { echo "$d"; return; }; done
}
DIR="${DIR_ARG:-$(find_dir)}"
[ -n "${DIR:-}" ] && looks_like_strata "$DIR" || {
  bad "Kein Strata-Baum gefunden."
  info "Ich suche ein CMakeLists.txt mit 'project(strata VERSION' — hier, eine Ebene hoeher,"
  info "../strata, ../Strata, ~/Machen/strata."
  info "Sag mir den Pfad direkt:  bash install.sh /pfad/zum/strata"
  exit 2
}
cd "$DIR" || exit 2
ENGINE_VERSION=$(sed -n 's/.*project(strata VERSION \([0-9.]*\).*/\1/p' CMakeLists.txt | head -1)
say "Strata-Baum: $PWD  (Engine $ENGINE_VERSION)"

if [ ! -e .git ]; then
  warn "Dieser Ordner ist kein Git-Baum — Patches lassen sich hier nicht sicher zuruecknehmen."
fi

# ---------- 2) Stand anzeigen ----------
HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
info "Stand: $HEAD   (Basis des Patches: 7726f80c = 0.2.13.1 / Engine 0.1.59.1)"
TRACKED=$(git status --porcelain 2>/dev/null | grep -vc '^??')
[ "$TRACKED" -eq 0 ] && ok "keine getrackten Aenderungen" || warn "$TRACKED getrackte Datei(en) veraendert"

probe_binary() {
  local b
  for b in engine/strata build/strata; do
    [ -x "$b" ] || continue
    local f; f=$("$b" --help 2>&1 | grep -oE "$PROBE" | sort -u | tr '\n' ' ')
    local kinetic="nein"
    if strings "$b" 2>/dev/null | grep -c "session-automaton" >/dev/null; then kinetic="ja"; fi
    printf '%s\n%s\n%s\n' "$b" "$f" "$kinetic"
    return 0
  done
  printf '\n\n\n'
}
show_binary() {
  local name feats kinetic
  { read -r name; read -r feats; read -r kinetic; } < <(probe_binary)
  if [ -z "$name" ]; then info "kein Bau gefunden (engine/strata, build/strata)"; return; fi
  if [ -n "$feats" ]; then
    ok "$name enthaelt: $feats  Kinetic: $kinetic"
  else
    info "$name enthaelt keine Patch-Merkmale — Patch ist nicht gebaut"
  fi
}
patch_in_source() {
  local n=0 f
  for f in "${NEW_FILES[@]}"; do [ -f "$f" ] && n=$((n+1)); done
  echo "$n"
}
diag_binary() {
  local b=engine/strata
  [ -x "$b" ] || b=build/strata
  [ -x "$b" ] || { info "kein Binary gefunden"; return; }
  info "Binary $b: Version $("$b" --version 2>&1 | head -1), Datei vom $(date -r "$b" '+%d.%m. %H:%M' 2>/dev/null)"
  if [ -f engine/BUILD.json ]; then
    info "engine/BUILD.json: source=$(sed -n 's/.*"source": *"\([a-z]*\)".*/\1/p' engine/BUILD.json | head -1) version=$(sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' engine/BUILD.json | head -1)"
  else
    info "engine/BUILD.json fehlt — dieser Binary wurde nicht von setup.sh gebaut"
  fi
  info "Quellversion in CMakeLists.txt: $(sed -n 's/.*project(strata VERSION \([0-9.]*\).*/\1/p' CMakeLists.txt | head -1)"
}

verify_engine() {
  show_binary
  local FOUND MISS w
  FOUND=$(probe_binary | sed -n '2p')
  MISS=""
  for w in turbo2 turbo3 k3v8 remote-stage stage-listen; do
    echo "$FOUND" | grep -qw "$w" || MISS="$MISS $w"
  done
  [ -z "$MISS" ] && { ok "Alle Kern-Merkmale gefunden: turbo2 turbo3 k3v8 remote-stage stage-listen"; return 0; }
  bad "fehlen im gebauten Binary:$MISS"
  diag_binary
  if [ "$(patch_in_source)" -lt "${#NEW_FILES[@]}" ]; then
    info "Quell und Binary passen nicht zusammen — bitte die Bau-Ausgabe hier her."
    return 1
  fi
  warn "Der Quell ist gepatcht, der Binary ist es nicht — setup.sh hat einen alten Bau weiterverwendet."
  say "Notfall: Engine von Hand bauen und in engine/ einsetzen"
  local NVCC="" c A ARCH=86 NINJA=ninja
  for c in "${CUDACXX:-}" /usr/local/cuda/bin/nvcc /usr/local/cuda-12.8/bin/nvcc /usr/bin/nvcc; do
    [ -n "$c" ] && [ -x "$c" ] && NVCC="$c" && break
  done
  if [ -z "$NVCC" ]; then bad "kein nvcc gefunden — Bau nicht moeglich"; info "CUDA-Toolkit installieren, dann erneut laufen lassen"; return 1; fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    A=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
    [ -n "$A" ] && ARCH="$A"
  fi
  [ -x .venv/bin/ninja ] && NINJA=.venv/bin/ninja
  info "nvcc=$NVCC  Architektur sm_$ARCH  Build-Ordner build/"
  rm -rf build
  CUDACXX="$NVCC" cmake -S . -B build -G Ninja -DSTRATA_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$ARCH" || { bad "cmake fehlgeschlagen"; return 1; }
  if ! "$NINJA" -C build strata; then bad "Bau fehlgeschlagen — Meldung oben"; return 1; fi
  mkdir -p engine
  [ -f engine/strata ] && mv engine/strata engine/strata.vorher
  cp build/strata engine/strata
  [ -f engine/BUILD.json ] && mv engine/BUILD.json engine/BUILD.json.vorher
  ok "neuer engine/strata eingesetzt (der alte liegt als engine/strata.vorher bereit)"
  info "Der Stempel engine/BUILD.json ist entfernt: das naechste ./setup.sh baut sauber weiter."
  FOUND=$(probe_binary | sed -n '2p')
  MISS=""
  for w in turbo2 turbo3 k3v8 remote-stage stage-listen; do
    echo "$FOUND" | grep -qw "$w" || MISS="$MISS $w"
  done
  if [ -n "$MISS" ]; then bad "immer noch fehlend:$MISS — bitte Bau-Ausgabe hier her"; return 1; fi
  show_binary
  ok "Nach dem Notfall-Bau sind alle Kern-Merkmale da"
  return 0
}

if [ "$MODE" = "status" ]; then
  say "Status"
  show_binary
  diag_binary
  n=$(patch_in_source)
  if [ "$n" -eq 0 ]; then info "im Quellbaum: kein Patch"
  elif [ "$n" -eq ${#NEW_FILES[@]} ]; then info "im Quellbaum: alle $n Patch-Neudateien da"
  else info "im Quellbaum: $n von ${#NEW_FILES[@]} Patch-Neudateien da — teils/alt"
  fi
  exit 0
fi

# ---------- 3) revert ----------
if [ "$MODE" = "revert" ]; then
  say "Patch zuruecknehmen"
  if git apply -R "$PATCH" 2>/dev/null; then ok "zurueckgenommen"; show_binary; exit 0; fi
  warn "dieser Patch laesst sich nicht sauber abnehmen — vermutlich liegt ein ANDERER (alter) Patch drauf."
  info "Alte Einzel-Patches abnehmen:"; info "  $OLD_REPO_HINT   (und ebenso: kinetic, multinode)"
  info "Danach:  git status --short   — es sollte nichts mehr veraendert sein."
  exit 1
fi

# ---------- 4) schon drauf? ----------
say "Pruefen"
if git apply --check "$PATCH" 2>/dev/null; then
  ok "Patch passt konfliktfrei"
  ALREADY=0
else
  ERR=$(git apply --check "$PATCH" 2>&1)
  if echo "$ERR" | grep -q "does not apply" && ! echo "$ERR" | grep -q "already exists"; then
    if git apply --check -R "$PATCH" 2>/dev/null; then
      ok "Patch liegt schon vollstaendig drauf — nichts zu tun"
      ALREADY=1
    else
      bad "Patch passt nicht auf diesen Stand."
      echo "$ERR" | sed 's/^/         /' | head -12
      say "Diagnose"
      info "a) der Baum steht auf einem anderen Commit als 7726f80c (aktuell: $HEAD),"
      info "   oder ein alter Patch liegt uncommittet darauf."
      info "b) ifoldiger Ausweg, immer in dieser Reihenfolge:"
      info "     git stash"
      info "     ./update.sh"
      info "     bash $HERE/apply_patch.sh check strata"
      info "   NIEMALS 'git stash pop' nach dem update — der alte Patch kollidiert mit dem neuen."
      exit 1
    fi
  else
    # nur "already exists": Ueberreste alter Turbo-/Kinetic-Patches
    if git apply --check -R "$PATCH" 2>/dev/null; then
      ok "Patch liegt schon vollstaendig drauf — nichts zu tun"
      ALREADY=1
    else
    warn "Patch passt noch nicht: Dateien liegen bereits im Weg."
    echo "$ERR" | grep "already exists" | sed 's/^/         /'
    say "Aufraeumen: Ueberreste alter Patches"
    info "Das sind die Neudateien der alten Turbo-/Kinetic-Patches aus pott/strata_patch."
    # alte Einzel-Patches zuerst sauber zuruecknehmen, wenn ihr Repo zu finden ist
    OLD_SH=""
    for cand in ../strata_patch/apply_patch.sh "$HERE/../strata_patch/apply_patch.sh"; do
      [ -f "$cand" ] && OLD_SH="$cand" && break
    done
    if [ -n "$OLD_SH" ]; then
      OLD_DIR="$(cd "$(dirname "$OLD_SH")" && pwd)"
      for p in strata/strata_all.patch strata_kinetic/strata_kinetic_all.patch strata_multinode/strata_multinode_all.patch; do
        [ -f "$OLD_DIR/$p" ] || continue
        if git apply --check -R "$OLD_DIR/$p" 2>/dev/null; then
          git apply -R "$OLD_DIR/$p" 2>/dev/null && info "alten Patch zurueckgenommen: $p"
        fi
      done
    fi
    # was steht noch im Weg?
    BLOCK=$(git apply --check "$PATCH" 2>&1 | grep "already exists" | sed 's/^error: //; s/: already exists.*//' | sort -u)
    if [ -z "$BLOCK" ]; then ok "nach dem Abnehmen alter Patches passt der Patch"; ALREADY=0
    else
      info "Im Weg liegen:"; echo "$BLOCK" | sed 's/^/           /'
      UNTRACKED=0; TRACKEDBLOCK=""
      while read -r f; do
        [ -z "$f" ] && continue
        if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then TRACKEDBLOCK="$TRACKEDBLOCK $f"; else UNTRACKED=$((UNTRACKED+1)); fi
      done <<< "$BLOCK"
      if [ -n "$TRACKEDBLOCK" ]; then
        bad "Diese Dateien sind COMMITTET:$TRACKEDBLOCK"
        info "Loeschen waere falsch. Stattdessen den Baum auf reinen Upstream bringen:"
        info "  git log --oneline -5      (nachsehen, welcher Commit den alten Patch brachte)"
        info "  git revert <commit>   oder   git checkout <upstream-commit> -- . "
        info "Danach erneut:  bash $HERE/install.sh $DIR_ARG"
        exit 1
      fi
      info "$UNTRACKED ungetrackte Ueberreste — die koennen weg, ohne dass etwas Verlorengeht."
      if [ "$FORCE_CLEAN" -eq 1 ]; then ANSWER=y
      else
        printf '  Ueberreste loeschen? [j/N] '; read -r ANSWER || ANSWER=""
      fi
      case "$ANSWER" in
        j|J|y|Y|ja|JA)
          while read -r f; do [ -n "$f" ] && rm -f -- "$f" && info "geloescht: $f"; done <<< "$BLOCK"
          find . -type d -empty -delete 2>/dev/null
          if git apply --check "$PATCH" 2>/dev/null; then ok "danach passt der Patch konfliktfrei"; ALREADY=0
          else bad "immer noch konfliktbehaftet:"; git apply --check "$PATCH" 2>&1 | sed 's/^/         /' | head -10; exit 1; fi
          ;;
        *) bad "ohne Loeschen geht es nicht — Abbruch. Manuell:  rm -f $(echo "$BLOCK" | tr '\n' ' ')"; exit 1 ;;
      esac
    fi
    fi
  fi
fi

if [ "$MODE" = "check" ]; then say "Ergebnis (--check-only)"; ok "Patch wuerde konfliktfrei angewandt"; exit 0; fi
if [ "$ALREADY" = "1" ]; then
  say "Nachweis: ist der Patch wirklich im gebauten Binary?"
  verify_engine || exit 1
  say "Fertig"
  info "Alles Weitere:  bash $HERE/test_und_aufraeumen.sh full"
  exit 0
fi

# ---------- 5) anwenden ----------
say "Anwenden"
git apply "$PATCH" || { bad "git apply fehlgeschlagen"; exit 1; }
n=$(git status --porcelain | grep -c '^')
ok "angewandt (nicht committet): $n Dateien im Baum"
[ "$n" -ge "$EXPECT_FILES" ] && ok "alle $EXPECT_FILES Patch-Dateien sind da" || warn "nur $n von $EXPECT_FILES — bitte melden"

if [ "$MODE" = "no-build" ]; then
  say "Fertig (ohne Bau)"; info "Bauen spaeter:  ./setup.sh --build --no-start"; exit 0
fi

# ---------- 6) bauen ----------
say "Bauen"
RUNNING=$(pgrep -f "engine/strata --serve" 2>/dev/null | head -1)
if [ -n "$RUNNING" ]; then
  warn "Engine laeuft gerade (PID $RUNNING) — der Zurückschiebe-Schritt kann 'Text file busy' melden."
  printf '  Engine stoppen fuer den Bau? [j/N] '
  if [ "$FORCE_CLEAN" -eq 1 ]; then ANSWER=y; else read -r ANSWER || ANSWER=""; fi
  case "$ANSWER" in j|J|y|Y|ja|JA) kill "$RUNNING" 2>/dev/null; sleep 3; info "Engine gestoppt";; *) info "Engine laeuft weiter — Bau versucht trotzdem";; esac
fi
BUILD_OK=0
if [ -x ./setup.sh ]; then
  if ./setup.sh --build --no-start; then ok "setup.sh --build --no-start durchgelaufen"; BUILD_OK=1
  else warn "setup.sh meldet Fehler — Notfall-Bau von Hand folgt"; fi
else
  warn "kein setup.sh gefunden — Notfall-Bau von Hand"
fi
if [ "$BUILD_OK" = "0" ]; then
  NVCC=""
  for c in "${CUDACXX:-}" /usr/local/cuda/bin/nvcc /usr/local/cuda-12.8/bin/nvcc /usr/bin/nvcc; do
    [ -n "$c" ] && [ -x "$c" ] && NVCC="$c" && break
  done
  [ -z "$NVCC" ] && { bad "kein nvcc gefunden — CUDA-Bau nicht moeglich"; info "Installation: cuda-keyring / nvidia-cuda-toolkit"; exit 1; }
  info "CUDA-Compiler: $NVCC"
  ARCH=86
  if command -v nvidia-smi >/dev/null 2>&1; then
    A=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
    [ -n "$A" ] && ARCH="$A" && info "GPU-Rechenwerk (nvidia-smi): $ARCH"
  fi
  NINJA=ninja; [ -x .venv/bin/ninja ] && NINJA=.venv/bin/ninja
  CUDACXX="$NVCC" cmake -S . -B build -G Ninja -DSTRATA_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$ARCH" || { bad "cmake fehlgeschlagen"; exit 1; }
  if "$NINJA" -C build strata; then ok "Notfall-Bau durchgelaufen"; BUILD_OK=1
  else bad "Bau fehlgeschlagen — Meldung oben im Bau-Log nachlesen"; exit 1; fi
fi

# ---------- 7) Nachweis ----------
say "Nachweis: ist der Patch wirklich drin?"
show_binary
verify_engine || exit 1

say "Fertig"
info "Alles Weitere:  bash $HERE/test_und_aufraeumen.sh full"
info "Rueckweg:       bash $HERE/install.sh --revert $DIR_ARG"
info "Kinetic wirkt erst mit  \"env\": {\"STRATA_LOOKUP_SESSION\":\"1\"}  und  --lookup-chain 6  in der Config."
info "Multinode wirkt erst mit  --remote-stage / --stage-listen  (siehe LESEN.md, Abschnitt 5 und 6)."
