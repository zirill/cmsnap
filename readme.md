# CMSnap-LITE — public benchmark

Reproduce the published [CMSnap-LITE](https://cmsnap.sqliteonline.com/) benchmarks
on your own machine. One script, nothing installed system-wide.

**Requirements:** Linux (x86_64 / arm64 / riscv64), `curl`, [`wrk`](https://github.com/wg/wrk).

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
5. write: public form POST (honeypot + per-IP limiter on)

Tunables: `DURATION=60 CONNS=100 SITES=100 PORT=8080`.
Results append to `results.txt`; `rm -rf run results.txt` removes every trace.

For publishable numbers: disable turbo, close background apps, run each test
three times, keep the median.
