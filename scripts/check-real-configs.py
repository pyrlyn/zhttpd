#!/usr/bin/env python3
"""Run `zhttpd -t` and `nginx -t` on real-world configs (read-only source).

Ivan's infra repo is only read: files are copied into .run/realconf/, Jinja templates are
rendered with sample values (every `{% if %}` takes its first branch, so the most
directives get exercised), absolute /etc/nginx/ includes are rebased onto the copy and
Let's Encrypt certificate paths point at bench/certs (self-signed). Server-level files
are wrapped in `events {} http { include mime.types; include FILE; }`.

usage: scripts/check-real-configs.py [INFRA_DIR]
"""
import os, re, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INFRA = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Grok/landing-pyrlyn-dev-nov10/infra")
RUN = os.path.join(ROOT, ".run", "realconf")
ZHTTPD = os.environ.get("ZHTTPD", os.path.join(ROOT, "zig-out", "bin", "zhttpd"))
NGINX = os.environ.get("NGINX", os.path.join(ROOT, "tools", "nginx", "sbin", "nginx"))
CERT = os.path.join(ROOT, "bench", "certs", "cert.pem")
KEY = os.path.join(ROOT, "bench", "certs", "key.pem")

VARS = {
    "site.domain": "example.test", "site.name": "example", "site.proxy_port": "8080",
    "site.repo": "n/a", "root": "/srv/www/example.test/current",
    "names": "example.test www.example.test", "indexnow_key": "0123456789abcdef",
    "ansible_managed": "Ansible managed", "deploy_containers_root": "/srv/landings",
}

def render_jinja(text):
    out, stack = [], []          # stack of "emit this branch?" flags
    for line in text.splitlines():
        tag = re.match(r"\s*{%-?\s*(\w+)(.*?)-?%}\s*$", line)
        if tag:
            kw = tag.group(1)
            if kw == "if":
                stack.append(True)
            elif kw in ("elif", "else"):
                stack[-1] = False
            elif kw == "endif":
                stack.pop()
            continue                       # `set`, `for`... lines are dropped
        if all(stack):
            def sub(m):
                expr = m.group(1).strip()
                name = re.split(r"\s*\|", expr)[0].strip()
                return VARS.get(name, "x")
            out.append(re.sub(r"{{(.*?)}}", sub, line))
    return "\n".join(out) + "\n"

def rebase(text, etc):
    text = re.sub(r"/etc/letsencrypt/live/[^/;\s]+/(fullchain|cert)\.pem", CERT, text)
    text = re.sub(r"/etc/letsencrypt/live/[^/;\s]+/privkey\.pem", KEY, text)
    return text.replace("/etc/nginx/", etc + "/")

def prepare():
    shutil.rmtree(RUN, ignore_errors=True)
    etc = os.path.join(RUN, "etc-nginx")
    os.makedirs(os.path.join(etc, "snippets"))
    os.makedirs(os.path.join(RUN, "prefix", "logs"))
    shutil.copy(os.path.join(ROOT, "tests", "fixtures", "nginx-default", "mime.types"), etc)
    # files that other configs include by name
    for d in ("sites/nginx/snippets",):
        for f in os.listdir(os.path.join(INFRA, d)):
            src = os.path.join(INFRA, d, f)
            with open(src) as fh:
                open(os.path.join(etc, "snippets", f), "w").write(rebase(fh.read(), etc))
    for d in ("web-proxy", "web-landing-kotlin"):
        for f in os.listdir(os.path.join(INFRA, d)):
            if f.endswith(".conf"):
                with open(os.path.join(INFRA, d, f)) as fh:
                    open(os.path.join(etc, f), "w").write(rebase(fh.read(), etc))
    return etc

CASES = [
    "paas/apps/landing-kotlin/nginx.conf",
    "paas/apps/cv/nginx.conf",
    "web-landing-kotlin/default.conf",
    "sites/nginx/front/sites-proxy.conf",
    "sites/nginx/conf.d/00-contabo-kit.conf",
    "sites/roles/nginx/templates/default.conf.j2",
    "sites/roles/nginx/templates/site.conf.j2",
    "web-proxy/proxy-tls.conf.j2",
]

def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()

def main():
    etc = prepare()
    rows = []
    for rel in CASES:
        src = os.path.join(INFRA, rel)
        if not os.path.exists(src):
            rows.append((rel, "missing", "missing", ""))
            continue
        text = open(src).read()
        if rel.endswith(".j2"):
            text = render_jinja(text)
        name = rel.replace("/", "__").replace(".j2", "")
        open(os.path.join(etc, name), "w").write(rebase(text, etc))
        main_conf = os.path.join(etc, "main-" + name)
        if re.search(r"^\s*http\s*{", text, re.M):
            shutil.copy(os.path.join(etc, name), main_conf)
        else:
            open(main_conf, "w").write(
                "error_log stderr;\nevents { worker_connections 64; }\n"
                f"http {{\n    include mime.types;\n    include {name};\n}}\n")
        prefix = os.path.join(RUN, "prefix") + "/"
        zrc, zout = run([ZHTTPD, "-t", "-p", prefix, "-c", main_conf])
        nrc, nout = (None, "nginx not built")
        if os.access(NGINX, os.X_OK):
            nrc, nout = run([NGINX, "-t", "-p", prefix, "-c", main_conf])
        rows.append((rel, zrc, nrc, zout, nout))
    print(f"{'config':48} {'zhttpd -t':10} {'nginx -t':10}")
    for r in rows:
        if r[1] == "missing":
            print(f"{r[0]:48} missing")
            continue
        rel, zrc, nrc, zout, nout = r
        st = lambda rc: "n/a" if rc is None else ("ok" if rc == 0 else "FAILED")
        print(f"{rel:48} {st(zrc):10} {st(nrc):10}")
        for line in zout.splitlines():
            if "[emerg]" in line or "[warn]" in line:
                print("    zhttpd:", line.replace(RUN, ".run/realconf"))
        if nrc not in (0, None):
            for line in nout.splitlines():
                if "[emerg]" in line:
                    print("    nginx: ", line.replace(RUN, ".run/realconf"))
    bad = [r for r in rows if r[1] not in (0, "missing") or (r[2] not in (None, 0) and r[2] != "missing")]
    sys.exit(1 if bad else 0)

main()
