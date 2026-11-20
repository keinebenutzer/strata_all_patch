# strata_all_patch — der eine Patch für die Strata-Engine

**Benutzung: siehe [LESEN.md](LESEN.md)** (Testen, Einspielen, Zurücknehmen).

**Stand:** Upstream-Basis `12d491da4` = Tag **v0.2.17** (Engine **0.1.63**). Ablöste Schnitte
bleiben als Tags erhalten: `archive/engine-all-on-58ee32277` (v0.2.16 / 0.1.62),
`archive/engine-all-on-c77572806` (v0.2.15), `archive/engine-all-on-7726f80c` (0.1.59.1).

Dieses Repo bündelt **alle Patches, die direkt die Strata-Engine betreffen**, zu **einem**
Groß-Patch: turbo2 + turbo3 + k3v8, Kinetic (Session-Lookup-Drafter) und Multinode (remote_stage).
Dazu unverändert der **PolyStrata-Patch** als eigener Baum. Wer die Einzel-Patches früher gestapelt
hat, braucht jetzt nur noch diesen einen.

**Nicht enthalten:** der split4-Patch (All-Cards-Split für 2–4 Karten). Er hat ein eigenes
Lieferrepo (`strata_split4_patch`), ebenfalls auf v0.2.17 geschnitten.

## Patches

| Datei | Basis | Inhalt |
|---|---|---|
| `strata_engine/strata_engine_all.patch` | Strata main `12d491da4` (v0.2.17 / Engine **0.1.63**) | **Der Sammel-Patch.** 36 Dateien, +3595/−91, 4833 Zeilen. Siehe Komponenten unten. |
| `polystrata/polystrata_all.patch` | PolyStrata main `4de79331` (0.1.45-poly.8) | Unverändert übernommen: deckt beide Engines des Forks ab (`strata`-Target **und** Kolibri `strata-poly` mit `--kv turbo2\|turbo3`, Parity-Test `poly_turbo_parity`). |

## Komponenten im Sammel-Patch

- **Warnbereinigung** — 13 Build-Warnungen auf 0.
- **turbo2** (2-Bit-KV, 320 B/Zelle) und **turbo3** (3-Bit, 448 B/Zelle) — derselbe Speicherplatz
  fasst mehr Kontext; die Decode-Kerne arbeiten direkt auf dem gepackten KV.
- **k3v8** (asymmetrisch: rotierte 3-Bit-Schlüssel + 8-Bit-Werte, 752 B/Zelle — die llama.cpp
  `-ctk/-ctv`-Idee).
- **setup-Menü** — Launcher/`setup.py` bietet alle sechs KV-Modi.
- **Kinetic** (Session-Lookup-Drafter): Suffix-Automaton über den ganzen Session-Verlauf statt nur
  über den Request. Wirkt in der `--lookup-chain`-Kette als zweite Quelle, eingeschaltet durch
  `STRATA_LOOKUP_SESSION=1`. Ohne Einschaltung ändert der Patch nichts am Verhalten. Gemessen auf
  einer RTX-3060-Maschine: +7,4 % warm (53,12 gegen 49,45 t/s); auf neuem Text kein Gewinn.
  A/B-Helfer: `strata_engine/kinetic_switch.sh`.
- **Multinode** (remote_stage): ein Layer-Split-Stadium auf einem **zweiten PC** über TCP
  (Hello/Window/Commit/Reset/Ping/Quit, Lockstep). Der VRAM-Bedarf verteilt sich über zwei Rechner;
  die Link trägt nur Hand-off-Blöcke pro Verify-Fenster, nicht die Gewichte. Flags: `--remote-stage`,
  `--stage-listen`, `--stage-layers`, `--stage-allow` (alle in `--help`). Ohne `--remote-stage`
  verhält sich die Engine wie ohne Patch. Auf EINER Karte kein Gewinn (gemessen, A4000: 51–57 t/s
  ohne gegen 24–29 mit `--remote-stage local --layer-split 40,44`).

## Baum-Layout seit 0.2.16 (unverändert in 0.2.17)

Der Engine-Quell liegt in `engine/` (`engine/CMakeLists.txt`, `engine/src`, `engine/include`,
`engine/cmake`), Terminal mit `setup.py`, `strata_cli`, `strata_control`, `serve` in `terminal/`,
die App in `app/`. Gebaut wird `cmake -S engine`, und `setup.py` legt den fertigen Engine in
**`terminal/engine/`** ab.

## Warum der Schnitt auf 0.2.17 Handarbeit brauchte

Upstream hat in `engine/src/program/generate.cpp` die Stadium-Zuweisung für Karten-Verbünde
umgebaut (P2P-Zuweisung). Die Sammel-Patch-Stelle für Multinode lag genau darüber; der Merge
behielt beide Blöcke und ergänzte die Übergabe-Zeiger (`hand_host`) für den Wirtspfad. Nach so
einer handsolved Stelle in einer Datei mit ~25000 Zeilen gilt: **Klammer-Bilanz prüfen, bevor
gebaut wird** — ein verschluckter Schleifen-Schließer sonst produziert über tausend
Fehlermeldungen, die unschuldige Zeilen nennen. Der Schnitt wurde auf zwei Produktivrechnern
(A4000 16 GB, RTX 3060 12 GB) gebaut und läuft dort.

## Was bewiesen ist

* **bewiesen (20.11.2026, Schnitt auf `12d491da4` = v0.2.17 / Engine 0.1.63):** Zyklus auf frischer
  Worktree — `check` konfliktfrei (36 Dateien), `apply`, gelegter Baum **null Zeilen** vom
  Patch-Schnitt entfernt, `revert` sauber (0 Dateien). Auf zwei Produktivrechnern gebaut
  (CUDA 12.8, `-DCMAKE_CUDA_ARCHITECTURES=86`): `strata` 0.1.63 fehlerfrei, `strata --help` nennt
  turbo2/turbo3/k3v8 und die vier Multinode-Schalter; beide Engines im Dauerbetrieb.
* **bewiesen (19.11.2026, Schnitt auf `58ee32277` = v0.2.16 / Engine 0.1.62, A4000 sm_86,
  CUDA 12.8):** `kv_turbo_parity` 11/11 bitgleich (turbo3 1.3042, k3v8-V 0.0325),
  `suffix_index_test` grün, `check_cuda_spills` ohne Verstoß aus den Patch-Dateien (upstream bringt
  eigenen: `i8_kernel` in `iq_kernels.cu`, STACK 8 auf sm_86), Launcher-Test
  `test_launch_tui.ContextStep` 6/6 — er prüft den KV-Zyklus `int8 → q4_0 → turbo3 → k3v8 → turbo2`
  in den Screens.

## Skripte — dafür da, dass niemand suchen muss

| Skript | Was es tut |
|---|---|
| `install.sh` | **Der geführte Weg.** Findet den Strata-Baum selbst (sucht `project(strata VERSION` in `.` , `..`, `../strata` …), zeigt den Stand, erkennt einen bereits angewandten Patch, räumt alte Einzel-Patches und ihre Überreste selbständig weg, wendet den Sammel-Patch an, baut (`setup.sh --build --no-start`, im Notfall von Hand mit gefundenem `nvcc` und korrekter GPU-Architektur) und **beweist** zum Schluss über die Feature-Abfrage am Binary, dass turbo2/turbo3/k3v8/Multinode wirklich drin sind. Optionen: `--check-only`, `--status`, `--no-build`, `--revert`, `--force-clean`, Pfad als Argument. |
| `test_und_aufraeumen.sh` | `cycle`: Prüfzyklus check → apply → revert auf einer **Wegwerf-Kopie** (dein Baum wird nicht angefasst), optional mit echtem Bau (`--build`). `cleanup`: alte Patches abnehmen, Überreste ihrer Neudateien auflisten und auf Wunsch löschen. `tests`: die Patch-Tests auf dem vorhandenen `build/`. `full`: alles drei. |

Beide Skripte melden auf Deutsch, was sie tun und warum sie abbrechen.

## Patch-Pflege

Bei einem Upstream-Sprung wird der Patch gegen den neuen Tag neu geschnitten; der Zyklus wird auf
einer frischen Worktree wiederholt, bevor ausgeliefert wird. Wo Upstream eine Fähigkeit selbst
übernommen hat, nimmt der neue Schnitt upstreams Version und lässt die eigene ersetzen — der README
sagt dann, welche Stellen das betrifft. Ablöste Schnitte bleiben als `archive/`-Tags erhalten.
