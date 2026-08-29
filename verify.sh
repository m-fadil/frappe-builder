#!/bin/sh
# Post-rollout check: does the frontend still reach the *current* backend, and
# does it serve assets? Catches nginx holding a dead container's IP after a swap.
#
#   ./verify.sh .env.alphafitness
set -eu

ENV_FILE=${1:?Usage: $0 <env-file>}
dc="docker compose --env-file $ENV_FILE"

ip_of() {
  $dc ps -q "$1" | head -1 |
    xargs docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

fail=0
check() { # check <label> <expected-code> <url>
  code=$($dc exec -T frontend curl -sS -o /dev/null -w '%{http_code}' "$3" || echo 000)
  if [ "$code" = "$2" ]; then
    echo "PASS  $1 ($code)"
  else
    echo "FAIL  $1 (got $code, want $2)"
    fail=1
  fi
}

echo "backend container IP: $(ip_of backend)"
echo "nginx last upstream : $(docker logs "$($dc ps -q frontend | head -1)" 2>&1 |
  grep -o 'upstream: "http://[0-9.]*:8000' | tail -1 | grep -o '[0-9.]*:8000' || echo none)"
echo "(if those two differ, nginx is on a stale IP — resolver cache)"
echo

check "frontend -> backend proxy" 200 http://localhost:8080/

asset=$($dc exec -T frontend curl -sS http://localhost:8080/ 2>/dev/null |
  grep -o '/assets/[^"]*\.css' | head -1 || true)
if [ -n "$asset" ]; then
  check "asset $asset" 200 "http://localhost:8080$asset"
else
  echo "SKIP  asset check (no /assets/*.css in HTML — page itself is broken)"
  fail=1
fi

exit $fail
