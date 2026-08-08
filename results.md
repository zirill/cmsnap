# Results — 32-core AMD EPYC 9554 (August 2026)

Engine: **CMSnap-LITE-M 0.2.2**, official release binary.
Harness: [`bench.sh`](bench.sh) from this repo — it downloads the binary,
pins the CPUs and drives the load itself. Raw wrk output for every run,
including the discarded ones: [`results-epyc32.txt`](results-epyc32.txt).

## Setup

| what | value |
|------|-------|
| hardware | AMD EPYC 9554 (KVM guest): 32 physical cores / 64 SMT threads — two 16-core CCDs with separate L3; 128 GB RAM; Debian 13, kernel 6.12 |
| server under test | pinned to the first CCD — 16 physical cores / 32 threads (`taskset 0-31`), its own L3 |
| load | wrk 4.1 on the second CCD (`taskset 32-63`, 32 threads) — full cache isolation from the server |
| runs | 10 s warmup, 180 s measurement; access log ON |
| page | the stock example site's landing page, ~11.4 KB, no compression requested |

```sh
SERVER_CPUS=0-31 LOAD_CPUS=32-63 THREADS=32 DURATION=180 CONNS=500 ./bench.sh <test>
```

## Cached page, one site — throughput vs latency

| connections |     req/s |    p50 |    p99 |
|------------:|----------:|-------:|-------:|
|         100 |   953,617 |  89 µs | 3.1 ms |
|         150 |   988,728 | 118 µs | 2.9 ms |
|         200 | 1,012,350 | 175 µs | 3.2 ms |
|         500 | 1,039,784 | 435 µs | 3.5 ms |
|        1000 | 1,042,959 | 900 µs | 4.1 ms |

**One CPU socket serves a million requests per second at a sub-200 µs
median.** The knee sits near 200 connections; past it, extra connections buy
queue depth, not throughput — the last 3% cost a fivefold median. The flat
~3 ms p99 is hypervisor scheduling jitter (it does not move with queue depth).

## Density — 10,000 full sites, not stubs

Every site is a complete clone of the example site: its own SQLite database
with 28 seeded articles, its own admin, users and keys. Routing by Host
header, an equal share to each site.

| sites on the node | cached page, req/s | page from database, req/s |
|------------------:|-------------------:|--------------------------:|
|                 1 |          1,039,784 |                         — |
|               100 |          1,057,618 |                   261,416 |
|            10,000 |            987,228 |                   241,535 |

**Ten thousand sites instead of one cost 5% of throughput and 30 µs of median
latency** (7.5% on the live-database path).

## Live database and JSON API (cache off, 100 sites)

| discipline | req/s | p50 | p99 |
|------------|------:|----:|----:|
| HTML page: SQLite read + template render per request | 255,302 | 416 µs | 2.3 ms |
| JSON API, ~50-row listing from a view | 293,123 | 406 µs | 1.2 ms |

## Writes scale with databases

The write test POSTs the public contact form — honeypot, per-IP rate limiter
and a redirect on every request. Durable rates are verified against bytes on
disk after each run.

| databases taking inserts | durable inserts/s |    p50 |    p99 |
|-------------------------:|------------------:|-------:|-------:|
|                        1 |          ~197,000 | 535 µs | 4.7 ms |
|                      100 |           494,769 | 491 µs |  99 ms |
|                   10,000 |           352,869 | 734 µs | 252 ms |

**A database per site turns isolation into write parallelism**: one database
drains ~197k inserts a second; spread the same flood across 100 sites and the
total more than doubles, because every site's database has its own writer.

The HTTP intake itself accepts 765k POSTs/s; past a writer's drain rate the
excess is shed to protect the site, behind a queue of 100,000 that absorbs
any realistic burst.

## Running a dense node

- A full site costs ~8 MB RSS and ~21 memory mappings with default settings.
- A 10,000-site node needs `vm.max_map_count` raised (the 65,530 default runs
  out near 3,000 sites: `sysctl -w vm.max_map_count=1048576`) and
  `ulimit -n` above the default 1024.
- Warm restart of the whole 10,000-site node — binary swap, config reload —
  is about 10 seconds to first served request.

## Discarded runs (and why)

The raw log keeps every run. Not counted above:

- runs with the server spanning both CCDs (shared L3 with the generator —
  45k req/s per core against 65k clean);
- runs with 16 wrk threads — the generator saturated before the server
  (~54k req/s is one wrk thread's ceiling);
- early write runs where all wrk threads emitted the same X-Real-IP
  sequence: 85% of responses were the per-IP limiter's 429, measuring the
  limiter instead of the engine. The script now stripes the IP space per
  thread.

## Reproduce it

```sh
curl -fsSL https://raw.githubusercontent.com/zirill/cmsnap/main/bench.sh | sh
```

Pin server and load to separate physical cores (`SERVER_CPUS` / `LOAD_CPUS`),
disable turbo, run each test three times, keep the median. Results append to
`results.txt` next to the machine's fingerprint.
