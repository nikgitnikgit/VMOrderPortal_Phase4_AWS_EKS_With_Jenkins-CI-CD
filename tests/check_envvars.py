import re, yaml, sys, os
os.chdir(os.path.join(os.path.dirname(__file__), ".."))

def reads(path):
    src = open(path).read()
    got = re.findall(r"os\.environ\.get\(\s*[\x27\x22](\w+)[\x27\x22]\s*(,)?", src)
    idx = re.findall(r"os\.environ\[[\x27\x22](\w+)[\x27\x22]\]", src)
    required = {n for n, d in got if not d} | set(idx)
    optional = {n for n, d in got if d}
    return required, optional

def supplied(chart):
    vals = yaml.safe_load(open(f"helm/{chart}/values.yaml"))
    cm = set(vals.get("config", {}).keys())
    # Phase 4: the Secret is created by scripts/bootstrap-platform.sh
    # (kubectl create secret) using values read from terraform outputs.
    boot = open("scripts/bootstrap-platform.sh").read()
    secret = set(re.findall(r"--from-literal=(\w+)=", boot))
    return cm | secret

fails = []
for svc, code in [("backend", "app/backend/app.py"), ("worker", "app/worker/worker.py")]:
    req, opt = reads(code)
    sup = supplied(svc)
    missing = req - sup
    if missing:
        fails.append(f"{svc}: code REQUIRES {sorted(missing)} but nothing supplies them")
    silent = opt - sup
    if silent:
        print(f"  note: {svc} vars using code defaults: {sorted(silent)}")
if fails:
    print("\n".join(fails)); sys.exit(1)
print("all required env vars are supplied")
