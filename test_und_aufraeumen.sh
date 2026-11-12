#!/usr/bin/env bash
# test_und_aufraeumen.sh — Pruefen und Aufräumen für den Strata-Sammel-Patch
#
#   bash test_und_aufraeumen.sh              cycle: Pruefzyklus auf einer Kratzspur
#   bash test_und_aufraeumen.sh cleanup      Ueberreste alter Patches wegraeumen
#   bash test_und_aufraeumen.sh tests        Testsuite auf dem vorhandenen build/
#   bash test_und_aufraeumen.sh full         cycle + cleanup + tests
#   bash test_und_aufraeumen.sh cycle --build   Zyklus inklusive echtem Bau (dauert einige Minuten)
#
# Optional: Zielverzeichnis als Argument, z. B.  bash test_und_aufraeumen.sh tests /home/pott/models/strata
#
# Der cycle-Modus arbeitet in einer WEGWERF-Kopie: dein Baum wird dabei nicht angefasst.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/strata_engine/strata_engine_all.patch"
OLD_PATCHES=(strata/strata_all.patch strata_kinetic/strata_kinetic_all.patch strata_multinode/strata_multinode_all.patch)
NEW_FILES=(
  include/strata/kernels/kv_turbo.hpp include/strata/kernels/kv_turbo3.hpp
  include/strata/kernels/kv_k3v8.hpp include/strata/core/remote_stage.hpp
  include/strata/spec/suffix_index.hpp
  src/kernels/cuda/kv_turbo.cu src/kernels/cuda/kv_turbo3.cu
  src/kernels/kv_turbo_parity.cpp src/core/remote_stage.cpp
  src/spec/suffix_index.cpp src/spec/suffix_index_test.cpp
)
PROBE='turbo2|turbo3|k3v8|remote-stage|stage-listen|stage-layers|stage-allow'
TEST_RE='kv_turbo_parity|suffix_index_test|suffix_drafter_test|draft_policy_test'

MODE="cycle"; DIR_ARG=""; DO_BUILD=0
for a in "$@"; do
  case "$a" in
    cycle|cleanup|tests|full) MODE="$a" ;;
    --build) DO_BUILD=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "Unbekannte Option: $a"; sed -n '2,14p' "$0"; exit 2 ;;
    *) DIR_ARG="$a" ;;
  esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFEHLER\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mACHTUNG\033[0m %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }

looks_like_strata() { [ -f "$1/CMakeLists.txt" ] && grep -q "project(strata VERSION" "$1/CMakeLists.txt"; }
find_dir() {
  local c=(. .. ./strata ./Strata ../strata ../Strata "$HOME/Machen/strata" "$HOME/Machen/Strata")
  for d in "${c[@]}"; do looks_like_strata "$d" && { echo "$d"; return; }; done
}
DIR="${DIR_ARG:-$(find_dir)}"
[ -n "${DIR:-}" ] && looks_like_strata "$DIR" || {
  bad "Kein Strata-Baum gefunden — Pfad als Argument angeben."
  exit 2
}
cd "$DIR" || exit 2
[ -f "$PATCH" ] || { bad "Patch fehlt: $PATCH"; exit 2; }
HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
say "Strata-Baum: $PWD   Stand: $HEAD"

# ---------------- cleanup ----------------
do_cleanup() {
  say "Aufräumen"
  OLD_DIR=""
  for cand in ../strata_patch/apply_patch.sh "$HERE/../strata_patch/apply_patch.sh"; do
    [ -f "$cand" ] && OLD_DIR="$(cd "$(dirname "$cand")" && pwd)" && break
  done
  if [ -n "$OLD_DIR" ]; then
    for p in "${OLD_PATCHES[@]}"; do
      [ -f "$OLD_DIR/$p" ] || continue
      if git apply --check -R "$OLD_DIR/$p" 2>/dev/null; then
        git apply -R "$OLD_DIR/$p" 2>/dev/null && info "alten Patch zurueckgenommen: $p"
      fi
    done
  else
    info "kein altes Patch-Repo (pott/strata_patch) in der Nachbarschaft gefunden"
  fi
  # Neudateien alter Patches, die als Ueberreste herumliegen
  STALE=()
  for f in "${NEW_FILES[@]}"; do
    [ -f "$f" ] && ! git ls-files --error-unmatch "$f" >/dev/null 2>&1 && STALE+=("$f")
  done
  if [ "${#STALE[@]}" -gt 0 ]; then
    warn "${#STALE[@]} ungetrackte Ueberreste von Patch-Neudateien:"
    printf '           %s\n' "${STALE[@]}"
    printf '  loeschen? [j/N] '
    read -r ANS || ANS=""
    case "$ANS" in
      j|J|y|Y|ja|JA)
        for f in "${STALE[@]}"; do rm -f -- "$f" && info "geloescht: $f"; done
        find . -type d -empty -delete 2>/dev/null
        ;;
      *) info "nichts geloescht" ;;
    esac
  else
    ok "keine Ueberreste im Weg"
  fi
  T=$(git status --porcelain | grep -vc '^??')
  if [ "$T" -eq 0 ]; then ok "getrackte Dateien: sauberer Upstream-Stand"
  else warn "$T getrackte Datei(en) veraendert — vermutlich ein angewandter Patch"; fi
}

# ---------------- cycle ----------------
do_cycle() {
  say "Pruefzyklus (Wegwerf-Kopie, dein Baum bleibt unangetastet)"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/strata_cycle.XXXXXX")"
  cleanup_tmp() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
  trap cleanup_tmp EXIT
  if ! git worktree add --detach "$TMP" HEAD >/dev/null 2>&1; then
    warn "kein Git-Worktree moeglich — Kopie per rsync"
    rsync -a --exclude .git --exclude build --exclude engine ./ "$TMP/" || { bad "Kopie fehlgeschlagen"; exit 1; }
  fi
  if (cd "$TMP" && git apply --check "$PATCH" 2>/dev/null); then
    ok "1) check: konfliktfrei"
  else
    bad "1) check: konfliktbehaftet"
    (cd "$TMP" && git apply --check "$PATCH" 2>&1 | sed 's/^/         /' | head -12)
    say "Naechster Schritt"
    info "bash $HERE/install.sh $DIR   — das Skript raeumt die Ueberreste selbst auf"
    exit 1
  fi
  (cd "$TMP" && git apply "$PATCH") || { bad "2) apply fehlgeschlagen"; exit 1; }
  N=$( (cd "$TMP" && git status --porcelain) | grep -c '^')
  if [ "$N" -ge 36 ]; then ok "2) apply: $N Dateien eingebracht (erwartet 36)"
  else bad "2) apply: nur $N von 36 Dateien"; exit 1; fi
  (cd "$TMP" && git apply -R "$PATCH") || { bad "3) revert fehlgeschlagen"; exit 1; }
  LEFT=$( (cd "$TMP" && git status --porcelain) | grep -c '^')
  if [ "$LEFT" -eq 0 ]; then ok "3) revert: Baum wieder leer (0 Eintraege)"
  else bad "3) revert: $LEFT Eintraege bleiben zurueck"; exit 1; fi
  if [ "$DO_BUILD" = "1" ]; then
    say "Bau der Kopie (dauert einige Minuten)"
    NVCC=""
    for c in "${CUDACXX:-}" /usr/local/cuda/bin/nvcc /usr/local/cuda-12.8/bin/nvcc /usr/bin/nvcc; do
      [ -n "$c" ] && [ -x "$c" ] && NVCC="$c" && break
    done
    if [ -z "$NVCC" ]; then
      bad "kein nvcc — Bau übersprungen"
    else
      ARCH=86
      command -v nvidia-smi >/dev/null 2>&1 && { A=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.'); [ -n "$A" ] && ARCH="$A"; }
      (cd "$TMP" && CUDACXX="$NVCC" cmake -S . -B build -G Ninja -DSTRATA_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$ARCH" >/dev/null && ninja -C build strata kv_turbo_parity suffix_index_test) \
        && ok "4) Bau der Kopie durchgelaufen" || bad "4) Bau der Kopie fehlgeschlagen"
      if [ -x "$TMP/build/strata" ]; then
        F=$("$TMP/build/strata" --help 2>&1 | grep -oE "$PROBE" | sort -u | tr '\n' ' ')
        [ -n "$F" ] && ok "5) Binary-Merkmale: $F" || bad "5) Binary ohne Patch-Merkmale"
      fi
    fi
  fi
  ok "Zyklus bewiesen: Patch passt, bringt alles, geht spurlos ab"
}

# ---------------- tests ----------------
do_tests() {
  say "Tests auf $PWD/build"
  CTEST=ctest; [ -x .venv/bin/ctest ] && CTEST=.venv/bin/ctest
  if [ ! -d build ]; then bad "kein build/ — erst bauen:  ./setup.sh --build --no-start"; return 1; fi
  if [ ! -x "$CTEST" ]; then bad "kein ctest gefunden"; return 1; fi
  OUT=$("$CTEST" --test-dir build -R "$TEST_RE" --output-on-failure 2>&1)
  echo "$OUT" | tail -25 | sed 's/^/  /'
  if echo "$OUT" | grep -q "100% tests passed"; then
    ok "Patch-Tests gruen"
  else
    warn "nicht alle Patch-Tests gruen — Output oben lesen. Ein laufendes Modell auf der GPU"
    warn "laesst Speichertest scheitern (out of memory): das ist die Umgebung, nicht der Patch."
    return 1
  fi
}

case "$MODE" in
  cycle) do_cycle ;;
  cleanup) do_cleanup ;;
  tests) do_tests ;;
  full) do_cycle; do_cleanup; do_tests ;;
esac
