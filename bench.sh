#!/bin/sh
# Reproduce the published CMSnap-LITE benchmarks on your own machine.
#
#   ./bench.sh            interactive menu
#   ./bench.sh 2          run test 2 directly
#
# The script downloads the OFFICIAL binary from the download site, unpacks
# the example site into ./run/ and drives wrk against it. Nothing is
# installed system-wide; `rm -rf run results.txt` removes every trace.
#
# Requirements: curl, wrk (https://github.com/wg/wrk).
# Tunables (env): DURATION=60 CONNS=100 THREADS=2 SITES=100 PORT=8080
#                 SERVER_CPUS=0,1 LOAD_CPUS=2,3   (taskset pinning, optional)
#
# For publishable numbers: pin server and load to DIFFERENT physical cores,
# disable turbo, close background apps, run each test 3 times, keep the
# median. Unpinned runs on a busy desktop are for orientation only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
run="$here/run"

DL=${DL:-https://sqliteonline.com/cmsnap/dl}
DURATION=${DURATION:-60}
CONNS=${CONNS:-100}
SITES=${SITES:-100}
PORT=${PORT:-8080}

command -v curl >/dev/null 2>&1 || { echo "error: curl not found" >&2; exit 1; }
if ! command -v wrk >/dev/null 2>&1; then
    inst=""
    if   command -v apt-get >/dev/null 2>&1; then inst="apt-get update && apt-get install -y wrk"
    elif command -v dnf     >/dev/null 2>&1; then inst="dnf install -y wrk"
    elif command -v pacman  >/dev/null 2>&1; then inst="pacman -S --noconfirm wrk"
    elif command -v apk     >/dev/null 2>&1; then inst="apk add wrk"
    fi
    sudo=""; [ "$(id -u)" = 0 ] || sudo="sudo "
    if [ -n "$inst" ]; then
        printf 'wrk not found — install it now (%s%s)? [y/N] ' "$sudo" "$inst"
        read -r a </dev/tty 2>/dev/null || a=n
        case "$a" in y|Y) ${sudo:+sudo }sh -c "$inst" || true ;; esac
    fi
    command -v wrk >/dev/null 2>&1 || {
        echo "error: wrk not found — no package on this distro (Debian has none); build it: https://github.com/wg/wrk" >&2
        exit 1
    }
fi

# CPU pinning: physical topology from `lscpu -e` — the server gets ~2/3 of
# the physical cores (with their SMT siblings), the load generator gets the
# rest, no overlap (6 cores → 4+2, 4 → 3+1). SERVER_CPUS/LOAD_CPUS override.
if [ -z "${SERVER_CPUS:-}" ] && command -v lscpu >/dev/null 2>&1; then
    pins=$(lscpu -e=CPU,CORE 2>/dev/null | awk '
        NR > 1 {
            if (!($2 in cpus)) order[++n] = $2
            cpus[$2] = cpus[$2] == "" ? $1 : cpus[$2] "," $1
        }
        END {
            if (n < 2) exit
            load = int(n / 3); if (load < 1) load = 1
            srv = n - load
            for (i = 1; i <= srv; i++) s = (i == 1 ? "" : s ",") cpus[order[i]]
            for (i = srv + 1; i <= n; i++) l = (i == srv + 1 ? "" : l ",") cpus[order[i]]
            print s " " l " " srv " " load
        }')
    if [ -n "$pins" ]; then
        SERVER_CPUS=$(echo "$pins" | cut -d' ' -f1)
        LOAD_CPUS=$(echo "$pins" | cut -d' ' -f2)
        echo "== topology: $(echo "$pins" | cut -d' ' -f3) phys cores for the server (cpus $SERVER_CPUS), $(echo "$pins" | cut -d' ' -f4) for the load (cpus $LOAD_CPUS)"
    fi
fi
pin_server=""; pin_load=""
if [ -n "${SERVER_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
    pin_server="taskset -c $SERVER_CPUS"
    pin_load="taskset -c ${LOAD_CPUS:?set LOAD_CPUS when SERVER_CPUS is set}"
else
    echo "note: no CPU pinning (single core or no lscpu/taskset) — numbers will be noisy"
fi

# One wrk thread per logical CPU of the load set (SMT-aware); THREADS overrides.
if [ -z "${THREADS:-}" ]; then
    if [ -n "${LOAD_CPUS:-}" ]; then
        THREADS=$(echo "$LOAD_CPUS" | awk -F, '{ print NF }')
    else
        THREADS=2
    fi
fi

# ── 1. official binary, verified ─────────────────────────────────────
case "$(uname -m)" in
    x86_64)        bin_name=cms-amd64 ;;
    aarch64|arm64) bin_name=cms-arm64 ;;
    riscv64)       bin_name=cms-riscv64 ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
mkdir -p "$run"
if [ ! -x "$run/cms" ]; then
    echo "== downloading $DL/$bin_name"
    curl -fL --progress-bar -o "$run/cms" "$DL/$bin_name"
    chmod +x "$run/cms"
    "$run/cms" --version
fi

# ── environment block, written next to every result ──────────────────
cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
mem=$(awk '/MemTotal/ { printf "%.1f GiB RAM", $2 / 1048576 }' /proc/meminfo)
pins_txt="none"
[ -n "${SERVER_CPUS:-}" ] && pins_txt="server cpus $SERVER_CPUS, load cpus $LOAD_CPUS"
env_info="   $("$run/cms" --version) | $(uname -srm)
   ${cpu:-unknown CPU} ($(nproc) threads) | $mem
   pinning: $pins_txt | $(wrk -v 2>&1 | head -1 | cut -d' ' -f1-2)"

# ── 2. example site (the same one every visitor gets) ────────────────
if [ ! -d "$run/www" ]; then
    echo "== unpacking the example site (admin password prints below — not needed for the bench)"
    ( cd "$run" && ./cms def-help )
    # Local loopback bind + trusted_proxies 127.0.0.1: the write test cycles
    # X-Real-IP through the trusted proxy so the per-IP form limiter sees
    # distinct clients (the engine is measured, not the limiter).
    ( cd "$run" && ./cms tune proxy --port "$PORT" )
fi

# ── wrk lua helpers (written next to the node) ───────────────────────
cat > "$run/hosts.lua" <<'EOF'
-- Round-robin the Host header across N sites (SITES env), equal share
-- each — the multi-site routing is part of what the benchmark measures.
-- BENCH_PATH overrides the request path (default /).
local n = tonumber(os.getenv("SITES") or "100")
local path = os.getenv("BENCH_PATH") or "/"
local i = 0
request = function()
    i = i % n + 1
    return wrk.format("GET", path, { Host = string.format("site%04d.test", i) })
end
EOF
cat > "$run/post.lua" <<'EOF'
-- POST the example site's public contact form. The 10/8 space is cut
-- into one stripe per wrk thread (setup numbers them): threads all count
-- from zero, so a shared sequence would send every IP once PER THREAD
-- and trip the per-IP form limiter. Striped, no IP repeats within a run
-- — the engine is measured, not the limiter (bench.sh set the
-- trusted-proxy mode via `cms tune proxy`).
local counter = 0
setup = function(thread)
    thread:set("tid", counter)
    counter = counter + 1
end
-- WRITE_FANOUT=N (test 6) rotates the Host header across N sites, so
-- every site's own database takes inserts at once; 0 = default site only.
local stride = math.floor(2 ^ 24 / tonumber(os.getenv("THREADS") or "32"))
local fan = tonumber(os.getenv("WRITE_FANOUT") or "0")
local i = 0
local body = "name=Load&email=l%40t.io&message=hello+from+bench"
request = function()
    i = i + 1
    local n = tid * stride + i % stride
    local hdr = { ["Content-Type"] = "application/x-www-form-urlencoded",
                  ["X-Real-IP"] = string.format("10.%d.%d.%d",
                      math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) }
    if fan > 0 then
        hdr["Host"] = string.format("site%04d.test", (i + tid) % fan + 1)
    end
    return wrk.format("POST", "/api/feedback", hdr, body)
end
EOF

# ── 3. multi-site node: clone the example into N sites ───────────────
build_sites() {
    # Rebuilt whenever the clone count and $SITES disagree — a stale node
    # would route the extra Hosts to the default site and fake the numbers.
    have=$(ls -d "$run/www/site"[0-9]* 2>/dev/null | wc -l)
    [ "$have" -eq "$SITES" ] && return 0
    echo "== building $SITES sites (copies of the example)"
    rm -rf "$run/www/site"[0-9]*
    src=$(ls -d "$run/www/"* | head -1)
    # Seed the example db once — every clone copies it ready-made, so the
    # first start of the N-site node opens files instead of running N seeds.
    if [ ! -d "$src/db" ]; then
        echo "-- seeding the example site db (one-off)"
        start_server
        stop_server
    fi
    i=1
    while [ "$i" -le "$SITES" ]; do
        cp -r "$src" "$run/www/$(printf 'site%04d' "$i")"
        i=$((i + 1))
    done
    {
        printf '{\n  "server": { "host": "127.0.0.1", "port": %s, "max_body_size": 65536,\n' "$PORT"
        printf '              "trusted_proxies": ["127.0.0.1"], "default": "site0001.test" },\n'
        printf '  "cache": { "enabled": true, "mem_percent": 20, "ttl_minutes": 10,\n'
        printf '             "hot_per_minute": 30, "max_entry": "512k" },\n'
        printf '  "access_log": {},\n  "site": {\n'
        i=1
        while [ "$i" -le "$SITES" ]; do
            sep=','; [ "$i" -eq "$SITES" ] && sep=''
            printf '    "site%04d.test": "site%04d"%s\n' "$i" "$i" "$sep"
            i=$((i + 1))
        done
        printf '  }\n}\n'
    } > "$run/settings.json"
}

# ── server lifecycle ─────────────────────────────────────────────────
pid=""
start_server() {
    ( cd "$run" && exec $pin_server ./cms run >server.log 2>&1 ) &
    pid=$!
    while ! curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/"; do
        kill -0 "$pid" 2>/dev/null || { echo "server died — see run/server.log" >&2; exit 1; }
        sleep 0.2
    done
}
stop_server() {
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=""
}
trap stop_server EXIT

cache() { # cache on|off in the root settings.json
    case "$1" in
        on)  sed -i 's/"enabled": false/"enabled": true/'  "$run/settings.json" ;;
        off) sed -i 's/"enabled": true/"enabled": false/' "$run/settings.json" ;;
    esac
}

# Test 5 fills the default site's feedback table — start every run from
# the seeded state (the server rebuilds a missing db/ on start), or runs
# would append onto each other's millions of rows.
reset_form_db() {
    dom=$(sed -n 's/.*"default": *"\([^"]*\)".*/\1/p' "$run/settings.json" | head -1)
    dir=""
    [ -n "$dom" ] && dir=$(sed -n "s/.*\"$dom\": *\"\([^\"]*\)\".*/\1/p" "$run/settings.json" | head -1)
    rm -rf "$run/www/${dir:-default}/db"
}

load() { # load [lua-script]
    echo "-- warmup 10s"
    SITES=$SITES THREADS=$THREADS WRITE_FANOUT=${wfan:-0} $pin_load wrk \
        -t"$THREADS" -c"$CONNS" -d10s ${1:+-s "$run/$1"} \
        "http://127.0.0.1:$PORT/" >/dev/null 2>&1 || true
    echo "-- measuring ${DURATION}s, ${THREADS}t/${CONNS}c"
    SITES=$SITES THREADS=$THREADS WRITE_FANOUT=${wfan:-0} $pin_load wrk \
        -t"$THREADS" -c"$CONNS" -d"${DURATION}s" --latency ${1:+-s "$run/$1"} \
        "http://127.0.0.1:$PORT/" | tee -a "$here/results.txt"
}

run_test() {
    echo "== $2" | tee -a "$here/results.txt"
    { date -u '+%Y-%m-%d %H:%M UTC'; echo "$env_info"; } >> "$here/results.txt"
    case "$1" in
        1) cache on;  start_server; load ;;
        2) build_sites; cache on;  start_server; load hosts.lua ;;
        3) build_sites; cache off; start_server; load hosts.lua; cache on ;;
        4) build_sites; cache off; start_server
           BENCH_PATH=/api/docs load hosts.lua
           cache on ;;
        5) build_sites; reset_form_db; cache on; start_server; load post.lua ;;
        # Spread writes leave ~10-20k rows per site per run — too shallow to
        # move insert cost, so only the default site's db is reset.
        6) wfan=$SITES
           build_sites; reset_form_db; cache on; start_server; load post.lua ;;
    esac
    stop_server
    echo | tee -a "$here/results.txt"
}

menu() {
    # Called as $(menu): stdout is captured, so everything meant for the
    # eye goes to stderr — only the picked number is the "return value".
    cat >&2 <<'EOF'
CMSnap-LITE public benchmark — pick a test:
  1) cached page, 1 site           (the "page from cache" discipline)
  2) cached page, N sites          (multi-site Host routing, default N=100)
  3) page from database, N sites   (cache off: SQLite read + render per request)
  4) JSON API, cache off           (/api/docs on every site)
  5) write: public form POST       (honeypot + per-IP limiter on, X-Real-IP cycled)
  6) write across N sites          (POSTs fan out by Host: every site's db takes inserts)
EOF
    printf 'test [1-6]: ' >&2
    read -r t </dev/tty
    echo "$t"
}

t=${1:-$(menu)}
case "$t" in
    1) run_test 1 "cached page, 1 site" ;;
    2) run_test 2 "cached page, $SITES sites" ;;
    3) run_test 3 "page from database (cache off), $SITES sites" ;;
    4) run_test 4 "JSON API /api/docs (cache off), $SITES sites" ;;
    5) run_test 5 "write: POST /api/feedback, one site ($SITES-site node)" ;;
    6) run_test 6 "write across sites: POST /api/feedback, $SITES sites" ;;
    *) echo "unknown test '$t'" >&2; exit 1 ;;
esac
echo "results appended to results.txt"
