#!/bin/bash
# rdocker end-to-end check against the live mini. Self-cleaning; only touches containers named rde2e-*.
# Run: bash ~/.claude-dotfiles/scripts/rdocker/tests/e2e.sh      (exit 0 = all pass)
set -u
PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
pg_ok(){ # wire-level Postgres handshake through laptop localhost (SSLRequest -> 'N'/'S')
  /usr/bin/python3 -c "import socket,sys;s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),3);s.sendall(b'\x00\x00\x00\x08\x04\xd2\x16\x2f');sys.exit(0 if s.recv(1) in (b'N',b'S') else 1)" "$1"; }
wait_pg(){ for _ in $(seq 1 40); do docker exec "$1" pg_isready -U postgres -q 2>/dev/null && return 0; sleep 1; done; return 1; }
cleanup(){ docker rm -f $(docker ps -aq --filter name=rde2e-) >/dev/null 2>&1; rm -rf "$TMP"; }
TMP=$(mktemp -d); trap cleanup EXIT

check "status healthy" "rdocker status"
check "docker shim first on PATH" "[ \"\$(readlink ~/.local/bin/docker)\" = \"\$HOME/.claude-dotfiles/scripts/rdocker/docker-shim\" ]"

docker run -d --name rde2e-rand -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:17 >/dev/null
P=$(docker port rde2e-rand 5432 | head -1 | awk -F: '{print $NF}')
check "random-port container lands on the mini" "rdocker where rde2e-rand | grep -q ': mini'"
check "random port mirrored the moment run returns" "grep -q \"$P\" ~/.local/state/rdocker/forwards.json"
wait_pg rde2e-rand; sleep 1
check "postgres answers on laptop localhost:$P" "pg_ok $P"
check "exec -i psql < file" "echo 'select 41+1' | docker exec -i rde2e-rand psql -U postgres -At | grep -q 42"

docker run -d --name rde2e-fixed -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:55977:5432 postgres:17 >/dev/null
check "fixed port mirrored" "grep -q 55977 ~/.local/state/rdocker/forwards.json"

echo hi > "$TMP/f"
check "bind mount runs on the laptop" "docker run --rm -v $TMP:/w alpine cat /w/f | grep -q hi"
check "--network host runs on the laptop" "RDOCKER_VERBOSE=1 docker run --rm --network host alpine true 2>&1 | grep -q 'running locally'"

for i in 1 2 3; do docker run -d --name rde2e-par$i -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:17 >/dev/null & done; wait
allp=1; for i in 1 2 3; do wait_pg rde2e-par$i; Q=$(docker port rde2e-par$i 5432 | head -1 | awk -F: '{print $NF}'); pg_ok "$Q" || allp=0; done
check "3 parallel databases all reachable" "[ $allp = 1 ]"

fails=0; for i in $(seq 1 20); do docker ps -q >/dev/null 2>&1 & done; for j in $(jobs -p); do wait "$j" || fails=$((fails+1)); done
check "20 concurrent docker calls, no failures" "[ $fails = 0 ]"

M=$(ssh -S ~/.local/state/rdocker/fwd.sock -O check macmini-docker 2>&1 | grep -o 'pid=[0-9]*' | cut -d= -f2); [ -n "$M" ] && kill -9 "$M"; sleep 1
check "self-heals after the SSH tunnel dies" "docker ps -q"
sleep 2; check "mirrors restored after tunnel death" "pg_ok $P"

docker rm -f rde2e-rand rde2e-fixed >/dev/null; sleep 4
check "removed containers' mirrors cleaned up" "! grep -qE '\"($P|55977)\"|[^0-9]($P|55977)[,\\]]' ~/.local/state/rdocker/forwards.json"

ssh macmini-docker "lsof -nP -iTCP -sTCP:LISTEN" > "$TMP/l" 2>/dev/null
check "mini publishes container ports on loopback only" "! grep -E '^(ssh|limactl).*\\*:[0-9]+' $TMP/l | grep -v ':53 '"
check "launchd forwarder loaded" "launchctl list com.rdocker.forwarder"

echo; echo "rdocker e2e: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
