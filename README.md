# strata_all_patch — der eine Patch für die Strata-Engine

**Benutzung: siehe [LESEN.md](LESEN.md)** (Testen, Einspielen, Zurücknehmen).

## Skripte — dafür da, dass niemand suchen muss

| Skript | Was es tut |
|---|---|
| `install.sh` | **Der geführte Weg.** Findet den Strata-Baum selbst (sucht `project(strata VERSION` in `.` , `..`, `../strata`, `~/Machen/strata` …), zeigt den Stand, erkennt einen bereits angewandten Patch, räumt alte Einzel-Patches und ihre Überreste selbständig weg, wendet den Sammel-Patch an, baut (`setup.sh --build --no-start`, im Notfall von Hand mit gefundenem `nvcc` und korrekter GPU-Architektur) und **beweist** zum Schluss über die Feature-Abfrage am Binary, dass turbo2/turbo3/k3v8/Multinode wirklich drin sind. Optionen: `--check-only`, `--status`, `--no-build`, `--revert`, `--force-clean`, Pfad als Argument. |
| `test_und_aufraeumen.sh` | `cycle`: Prüfzyklus check → apply → revert auf einer **Wegwerf-Kopie** (dein Baum wird nicht angefasst), optional mit echtem Bau (`--build`). `cleanup`: alte Patches abnehmen, Überreste ihrer Neudateien auflisten und auf Wunsch löschen. `tests`: die Patch-Tests auf dem vorhandenen `build/`. `full`: alles drei. |

Beide Skripte melden auf Deutsch, was sie tun und warum sie abbrechen.

Dieses Repo bündelt **alle Patches, die direkt die Strata-Engine betreffen**, zu
**einem** Groß-Patch: turbo2 + turbo3 + k3v8, Kinetic (Session-Lookup-Drafter)
und Multinode (remote_stage). Dazu unverändert der **PolyStrata-Patch** als
eigener Baum. Wer bisher `strata_all`, `strata_kinetic_all` und
`strata_multinode_all` einzeln gestapelt hat, braucht jetzt nur noch diesen einen.

**Stand 12.11.2026:** Upstream-Basis `7726f80c` (0.2.13.1 / Engine **0.1.59.1**).
Der Sammel-Patch ist auf diesem Stand geschnitten und **frisch gebaut geprüft**
(cmake + Ninja, CUDA 12.8, `-DCMAKE_CUDA_ARCHITECTURES=86`). Der Upstream steht
derzeit auf `f33c8c30` (0.1.59.1-Launcher-Nachzug, keine Engine-Dateien) — der
Patch passt dorthin ebenfalls konfliktfrei.

**Nicht enthalten:** der split4-Patch (All-Cards-Split, 4×16 GB). Er wird
derzeit separat behandelt und liegt weiterhin in `pott/strata_patch`
(`strata_split4/`).

## Patches

| Datei | Basis | Inhalt |
|---|---|---|
| `strata_engine/strata_engine_all.patch` | Strata main `7726f80c` (0.2.13.1 / Engine **0.1.59.1**) | **Der Sammel-Patch.** 36 Dateien, +3599/−92. Siehe Komponenten unten. |
| `polystrata/polystrata_all.patch` | PolyStrata main `4de79331` (0.1.45-poly.8) | Unverändert übernommen aus `pott/strata_patch`: deckt beide Engines des Forks ab (`strata`-Target **und** Kolibri `strata-poly` mit `--kv turbo2\|turbo3`, Parity-Test `poly_turbo_parity`). |

## Komponenten im Sammel-Patch

- **Warnbereinigung** — 13 Build-Warnungen auf 0.
- **turbo2** (2-Bit-KV, 320 B/Zelle) und **turbo3** (3-Bit, 448 B/Zelle) —
  derselbe Speicherplatz fasst mehr Kontext; die Decode-Kerne arbeiten direkt
  auf dem gepackten KV.
- **k3v8** (asymmetrisch: rotierte 3-Bit-Schlüssel + 8-Bit-Werte, 752 B/Zelle —
  die llama.cpp `-ctk/-ctv`-Idee).
- **setup-Menü** — Launcher/`setup.py` bietet alle sechs KV-Modi.
- **Kinetic** (Session-Lookup-Drafter): Suffix-Automaton über den ganzen
  Session-Verlauf statt nur über den Request, mit Kinetic's Lag. Wirkt in der
  `--lookup-chain`-Kette als zweite Quelle, eingeschaltet durch
  `STRATA_LOOKUP_SESSION=1`. Ohne Einschaltung ändert der Patch nichts am
  Verhalten. Gemessen auf 8gb: +7,4 % warm (53,12 gegen 49,45 t/s); auf neuem
  Text kein Gewinn. A/B-Helfer: `strata_engine/kinetic_switch.sh`.
- **Multinode** (remote_stage): ein Layer-Split-Stadium auf einem **zweiten PC**
  über TCP (Hello/Window/Commit/Reset/Ping/Quit, Lockstep). Der VRAM-Bedarf
  verteilt sich über zwei Rechner; die Link trägt nur Hand-off-Blöcke pro
  Verify-Fenster, nicht die Gewichte. Flags: `--remote-stage`,
  `--stage-listen`, `--stage-layers`, `--stage-allow` (alle in `--help`).
  Ohne `--remote-stage` verhält sich die Engine wie ohne Patch. Auf EINER
  Karte kein Gewinn (gemessen 11.11.2026, A4000: 51–57 t/s ohne gegen 24–29
  mit `--remote-stage local --layer-split 40,44`).

Parity bitgleich, Engine-Läufe kohärent, Volltests grün (vorbestehende,
ortsabhängige Ausnahmen im README des Austauschordners nachgeliefert).

## Quellwahrheit (Ast in pott/strata_lokal)

Der Sammel-Patch ist aus dem Ast **`agent/hermes-all-01591`** geschnitten
(Basis `7726f80c`; Merge von `rebase/k3v8-01591`, Cherry-Pick von
`agent/hermes-kinetic` `403d1267`, Merge von `agent/hermes-multinode-01591`
inkl. der zwei Live-Lauf-Korrekturen von `ceb942ee`). Bei einem Upstream-Sprung
wird der Ast neu getragen und der Patch aus ihm neu geschnitten.

## Ablauf rund um `update.sh`

```bash
# im Strata-Arbeitsverzeichnis (main, unveränderter Upstream-Stand):
bash <dieses-repo>/apply_patch.sh revert strata .   # 1) Patch runter
./update.sh                                          # 2) Upstream ziehen
bash <dieses-repo>/apply_patch.sh apply  strata .   # 3) Patch wieder drauf
```

`check` vor `apply` zeigt konfliktfreie Anwendung an. Nach einem Upstream-Sprung
kann der Patch Konflikte melden — dann neu schneiden lassen (Quellwahrheit ist
der Ast oben).

## Verhältnis zu pott/strata_patch

`pott/strata_patch` bleibt der historische Einzel-Lieferort (strata,
polystrata, split4, kinetic, multinode einzeln). **Dieses Repo ist ab sofort
die Lieferform für die Engine-Patches**: ein Patch, ein Stapel, ein Bau.
Für den split4-Patch gilt das noch nicht — er bleibt bis auf Weiteres in
`pott/strata_patch/strata_split4/`.
