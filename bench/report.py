#!/usr/bin/env python3
"""Aggregate a bench/run.sh result directory into RESULTS.md.

Per (scenario, server): median requests/s over repetitions, min-max spread, median
p50/p90/p99 latency, non-2xx/error counts, and the machine load seen around the runs.
"""
import csv, json, os, statistics, sys

out = sys.argv[1]
runs = list(csv.DictReader(open(os.path.join(out, "runs.csv"))))
env = open(os.path.join(out, "env.txt")).read()

data = {}   # (scenario, server) -> list of dicts
for r in runs:
    path = os.path.join(out, r["file"])
    rec = {"load_before": float(r["load_before"] or 0), "load_after": float(r["load_after"] or 0), "ok": False}
    try:
        d = json.load(open(path))
        lat = d.get("latencyPercentiles") or {}
        codes = d.get("statusCodeDistribution") or {}
        errs = d.get("errorDistribution") or {}
        good = sum(v for k, v in codes.items() if k.startswith("2"))
        rec.update(ok=True, rps=d["summary"]["requestsPerSec"] * (good / max(1, sum(codes.values()) + sum(errs.values()))),
                   raw_rps=d["summary"]["requestsPerSec"],
                   p50=(lat.get("p50") or 0) * 1000, p90=(lat.get("p90") or 0) * 1000, p99=(lat.get("p99") or 0) * 1000,
                   bad=sum(v for k, v in codes.items() if not k.startswith("2")), errors=sum(errs.values()),
                   errtext="; ".join(f"{k} x{v}" for k, v in list(errs.items())[:2]))
    except Exception as e:  # noqa: BLE001
        rec["errtext"] = f"no result ({e.__class__.__name__})"
    data.setdefault((r["scenario"], r["server"]), []).append(rec)

scenarios = list(dict.fromkeys(r["scenario"] for r in runs))
servers = list(dict.fromkeys(r["server"] for r in runs))
med = lambda xs: statistics.median(xs) if xs else 0.0

def cell(sc, sv):
    rs = [x for x in data.get((sc, sv), []) if x["ok"]]
    if not rs:
        return None
    rps = [x["rps"] for x in rs]
    return {"rps": med(rps), "min": min(rps), "max": max(rps), "p50": med([x["p50"] for x in rs]),
            "p90": med([x["p90"] for x in rs]), "p99": med([x["p99"] for x in rs]),
            "bad": sum(x["bad"] for x in rs), "errors": sum(x["errors"] for x in rs),
            "errtext": next((x["errtext"] for x in rs if x.get("errtext")), ""),
            "load": med([(x["load_before"] + x["load_after"]) / 2 for x in rs]), "n": len(rs)}

desc = {
    "small": "612 B static file", "medium": "64 KiB static file", "large": "1 MiB static file",
    "baseline": "tiny dynamic answer (`return 200 \"3\"` / dusty handler)",
}
def describe(sc):
    parts = sc.split("-")
    proto, kind, ka, conns = parts[0].upper(), parts[1], parts[2], parts[3][1:]
    streams = f", {parts[4][1:]} streams per connection" if len(parts) > 4 and parts[4].startswith('p') else ""
    return f"{desc.get(kind, kind)}, {'keep-alive' if ka == 'ka' else 'new connection per request'}, {conns} connections{streams}"

lines = ["# zhttpd benchmark results", "",
         f"Raw data: `bench/results/{os.path.basename(out)}/` (oha JSON per run, runs.csv, load.log, nginx.conf).", "",
         "```", env.strip(), "```", "",
         "RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.",
         "Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs",
         "(load average is contextual, not CPU utilization). Per-run `.err` sidecars record CPU usage.",
         "`vs nginx` compares median RPS; use `check-target.py` to enforce throughput, p99 and errors.", ""]
for proto in ("http", "https", "h2", "h3"):
    scs = [s for s in scenarios if s.startswith(proto + "-")]
    if not scs:
        continue
    title = {'http': 'HTTP (plain)', 'https': 'HTTPS (TLS 1.3)', 'h2': 'HTTP/2 (TLS 1.3)', 'h3': 'HTTP/3 (QUIC / TLS 1.3)'}[proto]
    lines += [f"## {title}", ""]
    for sc in scs:
        lines += [f"### {sc}: {describe(sc)}", "",
                  "| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        base = cell(sc, "nginx")
        for sv in servers:
            c = cell(sc, sv)
            if not c:
                lines.append(f"| {sv} | failed | | | | | | {next((x.get('errtext','') for x in data.get((sc, sv), [])), '')} | |")
                continue
            vs = f"{c['rps'] / base['rps']:.2f}x" if base and base["rps"] else "-"
            errs = f"{c['bad']}/{c['errors']}" + (f" ({c['errtext']})" if c["errtext"] else "")
            lines.append(f"| {sv} | {c['rps']:,.0f} | {c['min']:,.0f}-{c['max']:,.0f} | {c['p50']:.2f} | {c['p90']:.2f} | {c['p99']:.2f} | {vs} | {errs} | {c['load']:.1f} |")
        lines.append("")
# Handshake-heavy: HTTPS with keep-alive off (new TLS handshake per request)
hs = [s for s in scenarios if s.startswith("https-") and "-noka-" in s]
if hs:
    lines += ["## Handshake-heavy (HTTPS, keep-alive off)", ""]
    for sc in hs:
        lines += [f"### {sc}: {describe(sc)}", "",
                  "| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        base = cell(sc, "nginx")
        for sv in servers:
            c = cell(sc, sv)
            if not c:
                lines.append(f"| {sv} | failed | | | | | | {next((x.get('errtext','') for x in data.get((sc, sv), [])), '')} | |")
                continue
            vs = f"{c['rps'] / base['rps']:.2f}x" if base and base["rps"] else "-"
            errs = f"{c['bad']}/{c['errors']}" + (f" ({c['errtext']})" if c["errtext"] else "")
            lines.append(f"| {sv} | {c['rps']:,.0f} | {c['min']:,.0f}-{c['max']:,.0f} | {c['p50']:.2f} | {c['p90']:.2f} | {c['p99']:.2f} | {vs} | {errs} | {c['load']:.1f} |")
        lines.append("")

lines += ["## Summary (median RPS)", "", "| scenario | " + " | ".join(servers) + " |", "|---|" + "---:|" * len(servers)]
for sc in scenarios:
    row = []
    for sv in servers:
        c = cell(sc, sv)
        row.append(f"{c['rps']:,.0f}" if c else "failed")
    lines.append(f"| {sc} | " + " | ".join(row) + " |")
lines.append("")

notes = os.path.join(os.path.dirname(os.path.abspath(__file__)), "NOTES.md")
if os.path.isfile(notes):
    body = open(notes).read().strip()
    # skip the title line, keep the rest under a stable heading
    rest = "\n".join(body.splitlines()[1:]).strip() if body.startswith("#") else body
    lines += ["## Notes and competitor differences", "", rest, ""]

open(os.path.join(out, "RESULTS.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines[-(len(scenarios) + 4):]))
