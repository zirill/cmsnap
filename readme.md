# CMSnap-LITE — public benchmark

Reproduce the published [CMSnap-LITE](https://cmsnap.sqliteonline.com/) benchmarks
on your own machine. One script, nothing installed system-wide.

**Requirements:** Linux (x86_64 / arm64 / riscv64), `curl`, [`wrk`](https://github.com/wg/wrk)
(if wrk is missing, the script offers to install it via your package manager).

```sh
curl -fsSL https://raw.githubusercontent.com/zirill/cmsnap/main/bench.sh | sh
```

Or keep the script around:

```sh
curl -fLO https://raw.githubusercontent.com/zirill/cmsnap/main/bench.sh && chmod +x bench.sh
./bench.sh        # interactive menu
./bench.sh 2      # or run a test directly
```

The script downloads the official binary, unpacks the example site into `./run/`
and drives wrk against it. It pins server and load to separate physical cores
automatically (override with `SERVER_CPUS` / `LOAD_CPUS`).

Tests:

1. cached page, 1 site
2. cached page, 100 sites (multi-site Host routing)
3. page from database, 100 sites (cache off: SQLite read + render per request)
4. JSON API, cache off (`/api/docs` on every site)
5. write: public form POST into one site's database (honeypot + per-IP limiter on)
6. write across N sites — the POSTs fan out by Host, every site's own database takes inserts at once

Every knob is an environment variable:

```sh
SITES=1000 ./bench.sh 2        # a 1000-site node instead of the default 100
DURATION=120 CONNS=400 ./bench.sh 3
```

- `SITES` — how many sites the node runs in tests 2–4 (default 100); the node
  is rebuilt automatically when the number changes
- `DURATION` — seconds per measurement (default 60, after a 10 s warmup)
- `CONNS` — connections wrk keeps open (default 100)
- `PORT` — server port (default 8080)
- `SERVER_CPUS` / `LOAD_CPUS` — override the automatic core split

Results append to `results.txt` together with the machine details (binary
version, kernel, CPU, RAM, pinning); `rm -rf run results.txt` removes every trace.

For publishable numbers: disable turbo, close background apps, run each test
three times, keep the median.
