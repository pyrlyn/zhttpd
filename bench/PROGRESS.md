# zhttpd bench progress

Updated: 2026-11-10 11:22 Europe/Kiev (EET, UTC+2).
Scratch tree: `~/Grok/zig-http-server` (local git, no commits, no GitHub repo/PR).
Host: Darwin, Apple M3 Max 16 CPU / 64 GiB, already running Lima `default` (4 GiB) and `tc-prod-1`/`tc-prod-2` (6 GiB each). `infra-test` is stopped. Those VMs are not touched.







## Latest (11:22 EET) — complete

- Official Linux ABBA run finished (exit 0, ports freed): `bench/results/20261110-090437-linux/`. Combined report: `bench/RESULTS.md`. Exact Linux conf: `bench/results/20261110-090437-linux/nginx.conf` (`use epoll`, `reuseport`, TLS 1.3, `http2 off`).
- Linux (4 vCPU, load ~3–7, tight spreads): small HTTP keep-alive zhttpd 341k / nginx 289k / dusty 200k (c64); 1 MiB HTTP tied at 11.5k; handshake HTTPS-noka essentially tied (zhttpd 9.77k / nginx 10.05k / dusty 9.72k). dusty leads only on `/baseline11` (409k vs zhttpd 407k).
- `limactl stop zhttpd-bench` only; instance left on disk. `default`, `infra-test`, Colima, and `tc-*` were not started, stopped, or edited by this work.
- Still out of scope: Apache, HTTP/2, HTTP/3, io_uring, GitHub repo/PR. A quieter Mac rerun would tighten the macOS tables but is not required for the Linux comparison.

## Latest (11:05 EET)

- Linux `--quick` finished cleanly (exit 0, ports freed, load 1.3–2.6 on the 4-CPU VM). Copied to `bench/results/20261110-090042-linux-quick/`. nginx.conf uses `use epoll` and `listen ... reuseport`. 3 s / 1-rep summary: http-small-ka zhttpd 340k / nginx 271k / dusty 201k; https-small-ka 263k / 242k / 215k; handshake 10.0k / 10.4k / 9.4k. Large file is a tie (~10.9k).
- Full Linux ABBA (`DURATION=10 REPS=2`) started at 11:04 EET in the guest work tree, with the Linux `ps` and leader-hash fixes. Do not kill it. After it finishes: copy to `bench/results/`, merge Linux tables into `bench/RESULTS.md`, `limactl stop zhttpd-bench` only.

## Latest (11:02 EET)

- Resumed after interrupt. Did **not** redo the Mac official run (`20261110-102246`) or rebuild tools.
- Lima now: `zhttpd-bench` Running (ours). `infra-test` is Running and `tc-prod-*` are Stopped — that changed since 10:37; those instances are still not touched.
- Linux tools already built in the guest (`~/zhttpd-tools`, event backend epoll, nginx 1.30.6, oha 1.16.0, dusty-arena). Project virtiofs is readable but writes return EPERM, so results stay in `$HOME/zhttpd-run` and will be copied out with `limactl cp`.
- Linux `--quick` is **in progress** (`$HOME/zhttpd-run`, started 09:00 UTC / 11:00 EET, load ~1.0). Early zhttpd numbers: http-small-ka-c64 340k, http-large-ka-c64 11k, http-small-noka-c64 92k. `ps -Ao` in `load.log` is a BSD flag and failed on Linux (cosmetic). Leader git hash is empty because the work tree has no `competitors/` checkout — will fix both before the full Linux run. Do not kill this job.
- After `--quick` finishes: copy results to `bench/results/`, fix `ps` + leader hash, run the full Linux ABBA (`DURATION=10 REPS=2`), merge Linux tables into `bench/RESULTS.md`, then `limactl stop zhttpd-bench` only.

## Latest (10:37 EET)

- Official Mac run `bench/results/20261110-102246/` finished (`DURATION=10 REPS=2` ABBA, ReleaseFast, reuseport). Ports freed, exit 0. Copied to `bench/RESULTS.md` with a caveats section: host load 7–35 and lagging 1-min loadavg make min-max spreads very wide (e.g. http-small-ka-c64 zhttpd 40k–70k). Do not treat vs-nginx ratios as a stable ranking until a quieter rerun or the Linux results exist.
- Median snapshot (noisy): small HTTP keep-alive zhttpd ahead of nginx, dusty behind except on `/baseline11` (dusty 64.7k / zhttpd 58.2k / nginx 50.0k). Handshake (https-noka) dusty 8.0k / zhttpd 6.4k / nginx 3.7k.
- `zhttpd-bench` is still Stopped. Next: `limactl start zhttpd-bench` only, then `setup-vm.sh` and `bench/run.sh` inside the VM.

## Latest (10:22 EET)

- `--quick` ReleaseFast run `20261110-101933` finished cleanly (exit 0, ports freed, no bind collisions). Dusty HTTPS now completes (no EADDRNOTAVAIL). Load climbed from 6.3 to ~29 while other Java/Zig work ran on the Mac — numbers are still noisy and 1-rep/3s. Summary RPS: http-small-ka zhttpd 26,938 / nginx 37,063 / dusty 11,167; https-small-ka 42,377 / 38,561 / 5,758; handshake https-noka 3,845 / 3,902 / 1,454.
- Earlier `20261110-100440` was a Debug zhttpd build; do not compare it to this run.
- `zhttpd-bench` Lima instance is **created and Stopped**. `default`, `infra-test`, `tc-prod-*` were not touched.
- Next: full Mac `bench/run.sh` (DURATION=10 REPS=2, all scenarios, ABBA). Then start only `zhttpd-bench` and run `bench/lima/setup-vm.sh` + the same bench on Linux.

## Running now (10:19 EET)

- Rebuilt `zhttpd` with `scripts/build-zhttpd.sh` (`-Doptimize=ReleaseFast -Dtls=true`). The 10:09 binary had DWARF; the previous `--quick` numbers in `20261110-100440` are therefore **Debug vs nginx Release**, not a fair language comparison. A new `--quick` (ReleaseFast, reuseport, start_server fix) started at 10:19:33 EET with load ~6.3. Official full ABBA run comes after that.
- `limactl create --name=zhttpd-bench` is downloading/converting the Ubuntu 24.04 image. The VM is **not started** yet (avoids stealing CPU from the Mac bench). Other Lima instances were not touched.
- Linux tool cache is already on the mount: `tools/linux/cache/oha-linux-arm64` and `zig-aarch64-linux-0.17.1.tar.xz`.

## Do not redo

- Zig server (`zhttpd`) already parses a real nginx.conf, serves static files, speaks HTTP/1.0+1.1 and TLS 1.3 (OpenSSL 3.5.9), uses kqueue on macOS and epoll on Linux, honours `reuseport`, `ssl_session_cache`, `ssl_protocols`, `http2 off` (warn + ignore), sendfile, open_file_cache, etc.
- nginx 1.30.6 and oha 1.16.0 are already built under `tools/` from `deps/` (no brew).
- Self-signed certs live in `bench/certs/` and are gitignored (`*` except `.gitignore`). Regenerator: `scripts/gen-certs.sh`.
- HttpArena `dusty-tuned` is cloned at `bench/competitors/HttpArena` (commit `5646c1d2a4f4656073430ce55ed39a5c9c2e6749`), patched for `PORT`/`TLS_PORT`/`STATIC_DIR` (and already reads `TLS_CERT`/`TLS_KEY`), built `--release=fast`.
- `bench/leaders.toml`, `bench/nginx.conf.in`, `bench/run.sh`, `bench/report.py` exist. HTTP/2 and HTTP/3 leader entries are stubs (`status = "todo"`).
- First complete run: `bench/results/20261110-100440/` (`--quick`, 1 rep, 3 s, load 8–12). Tables are in `bench/RESULTS.md`. Treat them as noisy preliminaries, not the official numbers.
- Run `bench/results/20261110-100920/` is **invalid**: a leftover zhttpd from the first run still held 48080/48443, `start_server` treated any successful curl as “up”, and later “nginx” samples may have hit that leftover. Discard this directory; do not merge it into RESULTS.md.

## Done this resume (so far)

- Inspected the tree, git status (unborn `main`, everything untracked), results, competitors, Lima inventory.
- Killed leftover zhttpd master PID 59370 (reparented to PID 1) and confirmed 48080/48443 are free.
- Confirmed nginx 1.30.6 has no io_uring support (no `aio uring` / liburing in this source). zhttpd’s event loop is kqueue/epoll only. io_uring is not feasible without a newer nginx and a new zhttpd backend — documented as deferred, not stubbed in as a fake.
- `reuseport` was implemented in zhttpd but missing from `bench/nginx.conf.in` — added in this resume.
- `start_server` race and PLAN.md / PROGRESS.md were missing — fixed / added in this resume.

## Still left (in order)

1. Keep this file current.
2. Finish script/docs: PLAN.md, reuseport in nginx.conf.in, start_server must require the new PID to own the port, stop/trap cleanup, platform-specific Linux binary paths, handshake section in the report, dusty differences in NOTES.md, root .gitignore.
3. Mac sanity `--quick` after the start_server fix, then a full ABBA run (`DURATION=10 REPS=2`, all scenarios) on this Mac. Record load; numbers will be noisy while other Lima VMs and desktop apps are running.
4. Create a **new** dedicated Lima VM named `zhttpd-bench` only (Ubuntu 24.04, 4 CPU / 4 GiB). Do **not** start, stop, or edit `default`, `infra-test`, Colima, or `tc-prod-*`.
5. Inside that VM: build Linux binaries under `tools/linux/` and `zig-out-linux/` (do not overwrite Darwin binaries), run the same bench with `use epoll;` + `reuseport`.
6. Apache is out of scope until asked (“Apache later”).
7. No GitHub repo, no PR, no brew, no system sysctl changes.

## Notes for the next interrupt

- Official results, once a clean run finishes, live in `bench/RESULTS.md` and `bench/results/<stamp>/`.
- Exact nginx.conf used by a run is copied next to that run’s RESULTS.md and also rendered to `bench/nginx.conf`.
- Linux VM name must stay `zhttpd-bench`.
- Host load average was ~10 at 10:16 EET (Chrome, Wox, HoldMyLid, Virtualization.framework for the other VMs, inference-runtime python). Do not present a 3 s / 1-rep / load-10 run as a fair comparison.
