#!/usr/bin/env bash
# apply_patch.sh [check|apply|revert] [strata|polystrata] [verzeichnis]
# Der EINE Groß-Patch auf/vom Strata-Engine-Baum. Vor update.sh: revert; danach: apply.
# strata     = Sammel-Patch: turbo2 + turbo3 + k3v8 + Kinetic + Multinode
#              (Basis 12d491da4 = v0.2.17 / Engine 0.1.63; aeltere Schnitte: Tags
#              archive/engine-all-on-58ee32277 und archive/engine-all-on-c77572806).
# polystrata = der PolyStrata-Fork-Patch (Basis 4de79331 = 0.1.45-poly.8), unveraendert.
# split4 wird hier NICHT gefuehrt — der All-Cards-Split hat ein eigenes Lieferrepo
# (strata_split4_patch).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-check}"
KIND="${2:-strata}"
DIR="${3:-.}"
case "$KIND" in
  strata)     PATCH="$HERE/strata_engine/strata_engine_all.patch" ;;
  polystrata) PATCH="$HERE/polystrata/polystrata_all.patch" ;;
  *) echo "Basis: strata | polystrata"; exit 2 ;;
esac
[ -f "$PATCH" ] || { echo "Patch fehlt: $PATCH"; exit 2; }
cd "$DIR"
case "$MODE" in
  check)  git apply --check "$PATCH" && echo "KP: konfliktfrei auf diesem Stand." ;;
  apply)  git apply "$PATCH" && echo "KP: angewandt (nicht committet).";;
  revert) git apply -R "$PATCH" && echo "KP: zurueckgenommen." ;;
  *) echo "Modus: check | apply | revert"; exit 2 ;;
esac
