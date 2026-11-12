# LESEN.md — Bedienung

## Der einfache Weg: ein Skript

Nicht selbst suchen, nicht selbst raten — `install.sh` findet den Strata-Baum,
prüft, räumt alte Patches und deren Überreste selbständig weg, spielt den
Sammel-Patch ein, baut und **beweist**, dass er drin ist:

```bash
cd ~/Machen/strata
bash ../strata_all_patch/install.sh
```

Es meldet auf Deutsch, was es tut, und fragt nur zweimal: ob Patch-Überreste
gelöscht und ob eine laufende Engine gestoppt werden darf. Weitere Formen:

```bash
bash ../strata_all_patch/install.sh --check-only   # nur prüfen, nichts ändern
bash ../strata_all_patch/install.sh --status       # Stand + ist der Patch drin?
bash ../strata_all_patch/install.sh --no-build     # patchen, später bauen
bash ../strata_all_patch/install.sh --revert       # zurücknehmen
bash ../strata_all_patch/install.sh --force-clean  # ohne Rückfragen durch
bash ../strata_all_patch/install.sh /pfad/zum/strata
```

Prüfen und Aufräumen allein:

```bash
bash ../strata_all_patch/test_und_aufraeumen.sh            # Zyklus auf Wegwerf-Kopie
bash ../strata_all_patch/test_und_aufraeumen.sh cleanup    # Überreste alter Patches weg
bash ../strata_all_patch/test_und_aufraeumen.sh tests      # Patch-Tests auf build/
bash ../strata_all_patch/test_und_aufraeumen.sh full       # alles drei
bash ../strata_all_patch/test_und_aufraeumen.sh cycle --build   # Zyklus mit echtem Bau
```

## Von Hand (falls du es genau sehen willst)

```bash
cd ~/Machen/strata
bash ../strata_all_patch/apply_patch.sh check strata    # 1) testen
bash ../strata_all_patch/apply_patch.sh apply   strata  # 2) einspielen
bash ../strata_all_patch/apply_patch.sh revert  strata  # 3) zurücknehmen
```

(Der Pfad `../strata_all_patch/` gilt, wenn der Patch-Ordner direkt neben dem
Strata-Ordner liegt — sonst entsprechend anpassen.)

Syntax immer: **zuerst der Modus** (`check` / `apply` / `revert`), **dann die
Basis** (`strata` oder `polystrata`), **dann optional das Zielverzeichnis**.
Kein `-C` wie bei git. Von jedem beliebigen Ordner aus funktioniert auch:

```bash
bash /pfad/zu/strata_all_patch/apply_patch.sh check strata ~/Machen/strata
```

## Kurz: was der Patch bringt

Ein Patch für alles, was die Engine direkt angeht (Basis `7726f80c`,
0.2.13.1 / Engine **0.1.59.1**):

- **turbo2/turbo3/k3v8**: KV in 10/14 Byte pro 32 Werte statt 16 — derselbe
  Speicherplatz fasst mehr Kontext, und die Decode-Kerne arbeiten direkt auf
  dem gepackten KV (kein Umschichten mehr pro Fenster).
- **Kinetic**: Session-Lookup-Drafter — dort, wo schon geschriebener Text
  wiederkehrt, +7,4 % warm (53,12 gegen 49,45 t/s auf 8gb); auf neuem Text
  kein Gewinn. Ohne Einschaltung (Abschnitt 5) ändert er nichts am Verhalten.
- **Multinode**: ein Layer-Split-Stadium auf einem **zweiten PC**. Der
  VRAM-Bedarf des Modells verteilt sich über zwei Rechner — die Head-Karte
  hält nur noch ihre eigenen Schichten samt Experten, die Schichten ab K1
  liegen samt ihrer Experten auf der Stage-Karte. Dadurch passt ein Modell,
  das auf einer Karte nicht (oder nur mit aggressiver Quantisierung) resident
  wäre, mit mehr Experten im Speicher; die Link trägt nur Hand-off-Blöcke pro
  Verify-Fenster, nicht die Gewichte. Kein Gewinn ohne zweiten PC: auf EINER
  Karte gemessen (11.11.2026, A4000) 51–57 t/s ohne gegen 24–29 t/s mit
  `--remote-stage local --layer-split 40,44`. Ohne `--remote-stage` verhält
  sich die Engine wie ohne Patch.


## 1. Testen — passt der Patch auf meinen Stand?

`check` meldet `KP: konfliktfrei auf diesem Stand.` → einspielen.

Fehler mit Konfliktzeilen → der Baum steht nicht auf der Basis des Patches
(strata: main `7726f80c`, polystrata: main `4de79331`), oder ein alter Patch
liegt uncommittet darauf. Dann: `git stash` → `./update.sh` → erneut testen.
**Nie `git stash pop` nach dem update** — der alte Patch kollidiert mit dem
neuen, der ihn ersetzt.

Wer die alten Einzel-Patches (strata_all + kinetic + multinode aus
`strata_patch`) schon drauf hat: erst alle drei `revert`en, dann diesen
hier `apply`en — nie beide Stapel gleichzeitig:

```bash
bash ../strata_patch/apply_patch.sh revert multinode
bash ../strata_patch/apply_patch.sh revert kinetic
bash ../strata_patch/apply_patch.sh revert strata
```

**Fehler `…: already exists in working directory`** (gemeldet auf 8gb,
12.11.2026, für `kv_turbo.hpp`, `kv_turbo3.hpp`, `suffix_index.hpp`,
`kv_turbo.cu`, `kv_turbo3.cu`, `kv_turbo_parity.cpp`, `suffix_index.cpp`,
`suffix_index_test.cpp`): das sind die **Neudateien der alten Turbo- und
Kinetic-Patches**, die als Überreste im Baum liegen, während die bearbeiteten
Dateien bereits sauber sind. Erst nachsehen, ob sie ungetrackt oder committet
sind:

```bash
git status --short -- include/strata/kernels/kv_turbo.hpp src/spec/suffix_index.cpp
```

- `??` (ungetrackt) → Überreste löschen und neu prüfen:
  `git clean -f -- include src` → erneut `check`. Geprüft: danach
  `KP: konfliktfrei`, `apply` bringt die 11 Neudateien des Sammel-Patches.
- getrackt / committet → nichts löschen; stattdessen den Baum auf den reinen
  Upstream-Stand bringen (`git log --oneline -5` nachsehen, dann die alten
  Patches per `revert` oder `git checkout -- .` abnehmen) und erneut `check`en.

## 2. Einspielen

`KP: angewandt (nicht committet).` — danach neu bauen. Der übliche Weg erkennt
die geänderten Quellen selbst (Hash der Engine-Quellen gegen `src` in
`engine/BUILD.json`) und kompiliert nur, was geändert ist:

```bash
./setup.sh --build --no-start
```

Das legt `engine/strata` (und `libstrata_kq.so`) neu ab und schreibt `BUILD.json`
neu. Von Hand über das vorhandene `build/`:
`cmake --build build --target strata -j"$(nproc)"`, dann
`cp build/strata engine/strata` und, wenn vorhanden,
`cp build/libstrata_kq.so engine/` — dabei bleibt der `src`-Hash in `BUILD.json`
stehen, beim nächsten `./setup.sh` wird also einmal umsonst neu gebaut.
Läuft `engine/strata` gerade, kann der Zurückschiebe-Schritt mit „Text file
busy“ fehlschlagen — erst die Engine stoppen, dann bauen (oder per `mv`
austauschen).

**Beim ersten eigenen Bau (cmake neu konfigurieren):** CUDA muss ausdrücklich
angestellt werden (`-DSTRATA_ENABLE_CUDA=ON`), und CMake wählt auf manchen
Maschinen die falsche GPU-Architektur von selbst (auf einer A4000 wurde `120`
gesetzt). Der Bau gelingt, aber jede KV-Kernel-Ausführung endet mit
`no kernel image is available for execution on the device`. Deshalb explizit:

```bash
cmake -S . -B build -G Ninja -DSTRATA_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86
ninja -C build strata
```

(`-DCMAKE_CUDA_ARCHITECTURES=86` ist auf A4000/A5000/RTX-3060 Pflicht.)

Nach dem Bau prüfen, dass der Patch wirklich drin ist (`--version` bleibt
unverändert, die Version hebt der Patch nicht):

```bash
./engine/strata --help | grep -o 'turbo2\|turbo3\|k3v8\|remote-stage\|stage-listen' | sort -u
```

Ohne Patch kommt nichts zurück, mit Patch erscheinen `k3v8 remote-stage stage-listen
turbo2 turbo3`. Committen ist optional; uncommittet lässt sich der Patch am
saubersten wieder abnehmen.

## 3. Zurücknehmen

`KP: zurueckgenommen.` — der Baum ist wieder im reinen Upstream-Stand.

## 4. Der Ablauf vor `update.sh` (Regelfall)

```bash
cd ~/Machen/strata
bash ../strata_all_patch/apply_patch.sh revert strata    # 1) Patch runter
./update.sh                                              # 2) Upstream ziehen
bash ../strata_all_patch/apply_patch.sh apply     strata # 3) Patch wieder rauf
```

Meldet der Patch nach einem Upstream-Sprung Konflikte, ist der Upstream über
die gepatchten Stellen hinweggegangen: erst mit `check` prüfen, dann neu
schneiden lassen (Quellwahrheit ist der Ast `agent/hermes-all-01591` in
`pott/strata_lokal`) oder die betroffenen Dateien per `git checkout -- <datei>`
zurücksetzen und erneut `apply` versuchen.

## 5. Kinetic einschalten (erst damit wirkt dieser Teil)

In der Config der Engine (z. B. `coder_local.json`):

```json
"env": { "STRATA_LOOKUP_SESSION": "1" },
```

und in `"args"` zwei Einträge mehr: `"--lookup-chain", "6"`
(`--lookup-chain` ist auf 0..7 begrenzt, `--lookup-chain-min` auf mindestens 3).
Danach die Engine neu starten. Ohne diese beiden Stücke läuft die Engine wie
vorher. A/B-Helfer für 8gb: `strata_engine/kinetic_switch.sh
<kinetic|chain_only|original>`.

Tests nach dem Bau:
`ctest --test-dir build -R 'suffix_index_test|suffix_drafter_test|draft_policy_test'`
— erwartet: drei grüne Tests.

## 6. Multinode benutzen

Auf der Stage-Maschine (zweiter PC): `--stage-listen` samt
`--stage-layers`/`--stage-allow`; auf der Head-Maschine `--remote-stage <host>`
plus `--layer-split`. Alle vier Flags stehen in `--help` mit ihrer Wirkung und
den Umgebungsreglern `STRATA_MN_GAP_MS`, `STRATA_MN_ADAPT`. Ohne diese Flags
passiert nichts.

## Wenn etwas nicht passt

`install.sh` erkennt die drei typischen Fälle und sagt, was zu tun ist:

| Meldung des Skripts | Bedeutung | Was es tut / was du tust |
|---|---|---|
| `Patch liegt schon vollständig drauf` | der Sammel-Patch ist bereits angewandt | nichts — höchstens `test_und_aufraeumen.sh tests` |
| `… already exists in working directory` | Überreste der **alten** Turbo-/Kinetic-Patches | Skript nimmt alte Patches selbst ab und fragt, ob die Überreste gelöscht werden |
| `Diese Dateien sind COMMITTET` | alter Patch steckt in Commits | Skript löscht **nichts**; Baum auf reinen Upstream bringen (`git log --oneline -5`) |
| `Patch passt nicht auf diesen Stand` | anderer Upstream-Commit oder Alt-Patch drauf | `git stash` → `./update.sh` → erneut `install.sh` |
| `Text file busy` beim Bauen | Engine läuft | Skript fragt, ob es sie stoppen darf |
| `fehlen im gebauten Binary` + `Quell ist gepatcht, der Binary ist es nicht` | `setup.sh` hat einen **alten** Engine-Bau weiterverwendet (der Stempel `engine/BUILD.json` sagt „passt“, der Binary ist aber von vor dem Patchen) | Skript baut von Hand neu und setzt `engine/strata` selbst ein; der alte bleibt als `engine/strata.vorher` erhalten |
| `kein nvcc gefunden` | CUDA-Toolkit fehlt | installieren, oder nur `--no-build` nutzen |

## Wenn der Nachweis fehlt („fehlen im gebauten Binary")

`setup.sh` kann „durchgelaufen" melden, obwohl `engine/strata` **von vor dem
Patchen** ist: es vergleicht den Stempel `engine/BUILD.json` mit dem Quell und
überspringt den Bau, wenn er passt. `install.sh` merkt das und baut von Hand neu.
Falls du es selbst sehen willst:

```bash
cd ~/models/strata
bash ../strata_all_patch/install.sh --status     # Binary, Stempel, Quellversion
cat engine/BUILD.json | head -6                  # source: local oder prebuilt?
./engine/strata --help 2>&1 | grep -o 'turbo2\|turbo3\|k3v8\|remote-stage' | sort -u
```

Lehrstück: **`--version` beweist nichts** (der Patch ändert die Version nicht) und
Strata schreibt die Hilfe auf **stderr** — deshalb immer `2>&1`. Der Beweis ist
die Feature-Abfrage am Binary.

## PolyStrata statt Strata

Überall einfach `strata` durch `polystrata` ersetzen. Der PolyStrata-Patch
(Basis `4de79331`, 0.1.45-poly.8) deckt beide Engines des Forks ab
(`strata`-Target und Kolibri `strata-poly` mit `--kv turbo2|turbo3`,
Parity-Test `poly_turbo_parity`). Er ist unverändert aus `pott/strata_patch`
übernommen.
