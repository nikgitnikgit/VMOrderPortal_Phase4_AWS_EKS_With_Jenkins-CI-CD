import yaml, re, glob, sys, os
os.chdir(os.path.join(os.path.dirname(__file__), "..", "helm"))
fails = []
for chart in ["backend", "worker", "frontend"]:
    vals = yaml.safe_load(open(f"{chart}/values.yaml"))
    def exists(path):
        cur = vals
        for p in path.split("."):
            if not isinstance(cur, dict) or p not in cur: return False
            cur = cur[p]
        return True
    for t in glob.glob(f"{chart}/templates/*.yaml"):
        for path in set(re.findall(r"\.Values\.([\w.]+)", open(t).read())):
            if not exists(path):
                fails.append(f"{t}: references .Values.{path} — not in values.yaml (typo?)")
if fails:
    print("\n".join(fails)); sys.exit(1)
print("all .Values.* paths used by templates exist in values.yaml")
