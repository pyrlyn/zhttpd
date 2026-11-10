# Linux bench VM (`zhttpd-bench`)

A new, dedicated Lima VM. It is the only VM this project may create or start.

Do **not** start, stop, delete, or edit:

- `default`
- `infra-test`
- Colima
- `tc-prod-1` / `tc-prod-2` (other work)

## Create and start

```bash
cd ~/Grok/zig-http-server
limactl list
limactl create --name=zhttpd-bench --tty=false bench/lima/zhttpd-bench.yaml
limactl start zhttpd-bench
limactl shell zhttpd-bench -- bash /Users/listepo/Grok/zig-http-server/bench/lima/setup-vm.sh
limactl shell zhttpd-bench -- bash /Users/listepo/Grok/zig-http-server/bench/run.sh
```

`setup-vm.sh` builds Linux binaries into `tools/linux/` and `zig-out-linux/` on
the mounted project directory and must not overwrite Darwin `tools/nginx`,
`tools/oha`, or `zig-out/`.

To stop only this VM when the Linux run is finished: `limactl stop zhttpd-bench`.
Leave the instance on disk (do not `limactl delete` unless asked).

## Notes from the first official Linux run (2026-11-10)

- The Ubuntu 24.04 image has `Europe/Kyiv` but not `Europe/Kiev`. Lima passes the Mac timezone, so first-boot cloud-init can fail the timezone module. A symlink `Europe/Kiev -> Kyiv` inside this VM unblocks it. SSH still works even if `limactl start` is slow to report “boot scripts finished”.
- Virtiofs of `~/Grok/zig-http-server` is readable but writes return `EPERM` from the guest. `setup-vm.sh` therefore installs tools under `$HOME/zhttpd-tools` (and Zig caches under `$HOME/zhttpd-build`). Results are written under `$HOME/zhttpd-run/bench/results/` and copied to the Mac with `tar` over `limactl shell`.
- The stock `ubuntu-24.04` template also installs containerd; the bench does not use it.
- `io_uring` is not used (nginx 1.30.6 has no `aio uring`; zhttpd is epoll-only).
