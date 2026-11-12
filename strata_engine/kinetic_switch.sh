#!/usr/bin/env bash
# kinetic_switch.sh <kinetic|chain_only|original>   auf 8gb
# kinetic  : neues Binary, STRATA_LOOKUP_SESSION=1, --lookup-chain 6
# chain_only: neues Binary, KEIN env, --lookup-chain 6   (nur Upstream-Kette)
# original : altes Binary, Original-Config (keine Kette)
set -uo pipefail
MODE="${1:?Modus fehlt: kinetic|chain_only|original}"
cd /home/pott/models/strata

PID=$(pgrep -f "serve/server.py --engine strata --config /home/pott/models/strata/coder_local.json" | head -1)
echo "Modus=$MODE  laufender Server-PID=$PID"

echo "--- Config ---"
case "$MODE" in
  kinetic)
    cp -p coder_local.json.bak-pre-kinetic coder_local.json
    .venv/bin/python - <<'PY'
import json
p="/home/pott/models/strata/coder_local.json"
c=json.load(open(p))
c["env"]={**(c.get("env") or {}),"STRATA_LOOKUP_SESSION":"1"}
a=list(c["args"])
if "--lookup-chain" not in a: a+=["--lookup-chain","6"]
c["args"]=a
json.dump(c,open(p,"w"),indent=1,ensure_ascii=False)
PY
    ;;
  chain_only)
    cp -p coder_local.json.bak-pre-kinetic coder_local.json
    .venv/bin/python - <<'PY'
import json
p="/home/pott/models/strata/coder_local.json"
c=json.load(open(p))
c["env"]={}
a=list(c["args"])
if "--lookup-chain" not in a: a+=["--lookup-chain","6"]
c["args"]=a
json.dump(c,open(p,"w"),indent=1,ensure_ascii=False)
PY
    ;;
  original)
    cp -p coder_local.json.bak-pre-kinetic coder_local.json
    ;;
  installed)
    # Patch drauf, aber aus: neues Binary, Original-Config (kein env, keine Kette)
    cp -p coder_local.json.bak-pre-kinetic coder_local.json
    ;;
esac
.venv/bin/python -c "import json;c=json.load(open('/home/pott/models/strata/coder_local.json'));print('env =',c['env']);print('lookup-chain =', ('--lookup-chain' in c['args']))"

echo "--- Engine stoppen ---"
[ -n "$PID" ] && kill "$PID"
for i in $(seq 1 40); do pgrep -f "engine/strata --serve" >/dev/null || break; sleep 1; done
sleep 2
pgrep -af "engine/strata|serve/server.py" | head -3
nvidia-smi --query-gpu=memory.used --format=csv,noheader

echo "--- Binary ---"
case "$MODE" in
  kinetic|chain_only|installed) cp -f engine/strata.kinetic engine/strata ;;
  original)           cp -f engine/strata.bak-kinetic engine/strata ;;
esac
sha256sum engine/strata | cut -c1-12
strings engine/strata | grep -c "session-automaton" | sed 's/^/session-automaton im Binary: /'

echo "--- Start ---"
nohup .venv/bin/python serve/server.py --engine strata --config /home/pott/models/strata/coder_local.json --port 11435 > /home/pott/kinetic_serve.log 2>&1 &
echo "neuer Server-PID $!"
