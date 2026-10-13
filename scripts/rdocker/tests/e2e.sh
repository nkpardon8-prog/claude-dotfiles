#!/bin/bash
# rdocker end-to-end check against the live mini. Self-cleaning: every container is named
# rde2e-<pid>-* and the EXIT trap removes ONLY the IDs this run recorded (plus their volumes).
# Run: bash ~/.claude-dotfiles/scripts/rdocker/tests/e2e.sh      (exit 0 = all pass)
#      E2E_DISRUPTIVE=1 bash .../e2e.sh   also kills the SHARED ssh master (affects every window)
# bash 3.2 compatible (macOS /bin/bash).
set -u
PASS=0; FAIL=0
PFX="rde2e-$$-"
FWD="$HOME/.local/state/rdocker/forwards.json"
FIXED_PORT=55977          # fixed-port test; high, unlikely to be in use
BUSY_PORT=55979           # held by a laptop listener for the busy-port case
EPH_LO=20000; EPH_HI=29999   # rdocker default ephemeral_port_range

ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP  $1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
pg_ok(){ # wire-level Postgres handshake through laptop localhost (SSLRequest -> 'N'/'S')
  /usr/bin/python3 -c "import socket,sys;s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),3);s.sendall(b'\x00\x00\x00\x08\x04\xd2\x16\x2f');sys.exit(0 if s.recv(1) in (b'N',b'S') else 1)" "$1"; }
wait_pg(){ for _ in $(seq 1 40); do docker exec "$1" pg_isready -U postgres -q 2>/dev/null && return 0; sleep 1; done; return 1; }
hport(){ docker port "$1" 5432 2>/dev/null | head -1 | awk -F: '{print $NF}'; }
fwd_has(){ # is port $1 in forwards.json tcp4?
  /usr/bin/python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if int(sys.argv[2]) in [int(x) for x in (d.get('tcp4') or [])] else 1)" "$FWD" "$1"; }
in_eph(){ [ -n "$1" ] && [ "$1" -ge "$EPH_LO" ] 2>/dev/null && [ "$1" -le "$EPH_HI" ]; }

TMP=$(mktemp -d)
IDS="$TMP/ids"; VOLS="$TMP/vols"; : > "$IDS"; : > "$VOLS"
BUSY_PID=""
track(){ # record a container ID (from run -d output or a cidfile) for cleanup
  [ -n "$1" ] && echo "$1" >> "$IDS"; }
run_d(){ # docker run -d ... ; records the ID, prints it
  local cid; cid=$(docker run -d "$@" 2>"$TMP/run.err"); local rc=$?
  cid=$(printf '%s' "$cid" | tail -1); track "$cid"; printf '%s' "$cid"; return $rc; }
cleanup(){
  [ -n "$BUSY_PID" ] && kill "$BUSY_PID" 2>/dev/null
  # IDs we recorded, plus anything carrying our per-run prefix (a run that died before printing
  # its ID); never anyone else's rde2e-* containers.
  ids=$(sort -u "$IDS"; docker ps -aq --no-trunc --filter "name=$PFX" 2>/dev/null)
  ids=$(printf '%s\n' $ids | sort -u)
  # anonymous volumes of our containers, so they can be removed even if rm -v skips them
  for id in $ids; do docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$id" 2>/dev/null; done \
    | tr ' ' '\n' | grep -v '^$' >> "$VOLS"
  [ -n "$ids" ] && docker rm -f -v $ids >/dev/null 2>&1
  for v in $(sort -u "$VOLS"); do docker volume rm "$v" >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- basics -------------------------------------------------------------------------------------
check "status healthy" "rdocker status"
check "docker shim first on PATH" "[ \"\$(command -v docker)\" = \"\$HOME/.local/bin/docker\" ] && [ \"\$(readlink ~/.local/bin/docker)\" = \"\$HOME/.claude-dotfiles/scripts/rdocker/docker-shim\" ]"

# --- random port --------------------------------------------------------------------------------
RAND="${PFX}rand"
run_d --name "$RAND" -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:17 >/dev/null
P=$(hport "$RAND")
check "random-port container lands on the mini" "rdocker where $RAND | grep -q ': mini'"
check "random port $P is in the ephemeral range" "in_eph '$P'"
check "random port mirrored the moment run returns" "fwd_has '$P'"
wait_pg "$RAND"; sleep 1
check "postgres answers on laptop localhost:$P" "pg_ok $P"
check "exec -i psql < file" "echo 'select 41+1' | docker exec -i $RAND psql -U postgres -At | grep -q 42"

# --- fixed port ---------------------------------------------------------------------------------
FIXED="${PFX}fixed"
run_d --name "$FIXED" -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:$FIXED_PORT:5432 postgres:17 >/dev/null
check "fixed port $FIXED_PORT mirrored" "fwd_has $FIXED_PORT"

# --- busy laptop port -> refused (exit 125), nothing created -----------------------------------
/usr/bin/python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(); time.sleep(60)' "$BUSY_PORT" &
BUSY_PID=$!; sleep 1
BUSY="${PFX}busy"
run_d --name "$BUSY" -e POSTGRES_PASSWORD=postgres -p 127.0.0.1:$BUSY_PORT:5432 postgres:17 >/dev/null
brc=$?
check "busy laptop port $BUSY_PORT -> exit 125 (got $brc)" "[ $brc = 125 ]"
check "busy laptop port -> no container left behind" "[ -z \"\$(docker ps -aq --filter name=$BUSY)\" ]"
kill "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null; BUSY_PID=""

# --- local-only routes --------------------------------------------------------------------------
echo hi > "$TMP/f"
check "bind mount runs on the laptop" "docker run --rm -v $TMP:/w alpine cat /w/f | grep -q hi"
check "--network host runs on the laptop" "RDOCKER_VERBOSE=1 docker run --rm --network host alpine true 2>&1 | grep -q 'running locally'"

# --- two parallel ephemeral runs get distinct ports ---------------------------------------------
for i in 1 2; do
  ( docker run -d --name "${PFX}eph$i" -p 127.0.0.1::5432 -e POSTGRES_PASSWORD=postgres postgres:17 \
      > "$TMP/eph$i.cid" 2>/dev/null ) &
done; wait
for i in 1 2; do track "$(tail -1 "$TMP/eph$i.cid" 2>/dev/null)"; done
E1=$(hport "${PFX}eph1"); E2=$(hport "${PFX}eph2")
check "parallel ephemeral ports in $EPH_LO-$EPH_HI ($E1, $E2)" "in_eph '$E1' && in_eph '$E2'"
check "parallel ephemeral ports are distinct" "[ -n '$E1' ] && [ '$E1' != '$E2' ]"

# --- 3 parallel databases -----------------------------------------------------------------------
for i in 1 2 3; do
  ( docker run -d --name "${PFX}par$i" -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:17 \
      > "$TMP/par$i.cid" 2>/dev/null ) &
done; wait
for i in 1 2 3; do track "$(tail -1 "$TMP/par$i.cid" 2>/dev/null)"; done
allp=1; for i in 1 2 3; do
  wait_pg "${PFX}par$i"; Q=$(hport "${PFX}par$i"); [ -n "$Q" ] && pg_ok "$Q" || allp=0
done
check "3 parallel databases all reachable" "[ $allp = 1 ]"

fails=0; pids=""
for _ in $(seq 1 20); do docker ps -q >/dev/null 2>&1 & pids="$pids $!"; done
for j in $pids; do wait "$j" || fails=$((fails+1)); done
check "20 concurrent docker calls, no failures" "[ $fails = 0 ]"

# --- shared ssh master kill (disruptive: every window's mirrors blip) ---------------------------
if [ "${E2E_DISRUPTIVE:-0}" = 1 ]; then
  M=$(ssh -S ~/.local/state/rdocker/fwd.sock -O check macmini-docker 2>&1 | grep -o 'pid=[0-9]*' | cut -d= -f2)
  [ -n "$M" ] && kill -9 "$M"; sleep 1
  check "self-heals after the SSH tunnel dies" "docker ps -q"
  sleep 2; check "mirrors restored after tunnel death" "pg_ok $P"
else
  skip "self-heals after the SSH tunnel dies (set E2E_DISRUPTIVE=1)"
  skip "mirrors restored after tunnel death (set E2E_DISRUPTIVE=1)"
fi

# --- mirrors cleaned after rm -------------------------------------------------------------------
docker rm -f -v "$RAND" "$FIXED" >/dev/null 2>&1; sleep 4
check "removed containers' mirrors cleaned up ($P, $FIXED_PORT)" "! fwd_has '$P' && ! fwd_has $FIXED_PORT"

# --- rdocker.keep survives a forced-critical clean ----------------------------------------------
KEEP="${PFX}keep"; NOKEEP="${PFX}nokeep"
docker run --cidfile "$TMP/keep.cid" --name "$KEEP" --label rdocker.keep=1 \
  -e POSTGRES_PASSWORD=postgres postgres:17 true >/dev/null 2>&1
track "$(cat "$TMP/keep.cid" 2>/dev/null)"
docker run --cidfile "$TMP/nokeep.cid" --name "$NOKEEP" \
  -e POSTGRES_PASSWORD=postgres postgres:17 true >/dev/null 2>&1
track "$(cat "$TMP/nokeep.cid" 2>/dev/null)"
KVOL=$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$KEEP" 2>/dev/null | awk '{print $1}')
NVOL=$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$NOKEEP" 2>/dev/null | awk '{print $1}')
[ -n "$KVOL" ] && echo "$KVOL" >> "$VOLS"; [ -n "$NVOL" ] && echo "$NVOL" >> "$VOLS"
check "keep/nokeep containers land on the mini" "rdocker where $KEEP | grep -q ': mini' && rdocker where $NOKEEP | grep -q ': mini'"
check "keep container has an anonymous volume" "[ -n '$KVOL' ]"
sleep 2
rdocker clean --only "$PFX" --force-critical --exited_rm_hours 0 > "$TMP/clean.out" 2>&1
crc=$?
check "rdocker clean --only $PFX --force-critical exits 0" "[ $crc = 0 ]"
check "keep-labelled stopped container survives clean" "docker inspect $KEEP"
check "keep container's anonymous volume survives clean" "[ -n '$KVOL' ] && docker volume inspect '$KVOL'"
check "non-keep stopped twin IS removed by clean" "! docker inspect $NOKEEP"
docker rm -v "$KEEP" >/dev/null 2>&1
[ -n "$KVOL" ] && docker volume rm "$KVOL" >/dev/null 2>&1

# --- mini exposure + daemon ---------------------------------------------------------------------
ssh macmini-docker "lsof -nP -iTCP -sTCP:LISTEN" > "$TMP/l" 2>/dev/null
check "mini publishes container ports on loopback only" "! grep -E '^(ssh|limactl).*\\*:[0-9]+' $TMP/l | grep -v ':53 '"
check "launchd forwarder loaded" "launchctl list com.rdocker.forwarder"

# --- Lima override precedence: a container port published on all interfaces (-p 55999:80, no IP)
# must still bind ONLY the mini's 127.0.0.1 (override.yaml hostIP), never *:55999 ---------------
LIMA_PORT=55999
LIMA="${PFX}lima"
run_d --name "$LIMA" -p $LIMA_PORT:80 nginx:alpine >/dev/null
for _ in $(seq 1 20); do
  ssh macmini-docker "lsof -nP -iTCP:$LIMA_PORT -sTCP:LISTEN" > "$TMP/lima" 2>/dev/null
  grep -q ":$LIMA_PORT" "$TMP/lima" && break; sleep 1
done
check "-p $LIMA_PORT:80 listens on the mini" "grep -q ':$LIMA_PORT' $TMP/lima"
check "-p $LIMA_PORT:80 binds mini loopback only (Lima override wins)" \
  "! grep -vE '(127\\.0\\.0\\.1|\\[::1\\]):$LIMA_PORT' $TMP/lima | grep -q ':$LIMA_PORT'"
docker rm -f "$LIMA" >/dev/null 2>&1

echo; echo "rdocker e2e: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
