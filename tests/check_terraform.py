import hcl2, glob, re, sys, os
os.chdir(os.path.join(os.path.dirname(__file__), "..", "terraform"))
def clean(k): return k.strip(chr(34))
errors, parsed = [], {}
for f in sorted(glob.glob("**/*.tf", recursive=True)):
    try: parsed[f] = hcl2.load(open(f))
    except Exception as e: errors.append(f"SYNTAX {f}: {e}")
mv, mo, md = {}, {}, {}
for mod in os.listdir("modules"):
    mv[mod], mo[mod], md[mod] = set(), set(), set()
    for f in glob.glob(f"modules/{mod}/*.tf"):
        for v in parsed.get(f, {}).get("variable", []):
            for n, b in v.items():
                if n == "__is_block__": continue
                mv[mod].add(clean(n))
                if isinstance(b, dict) and "default" in b: md[mod].add(clean(n))
        for o in parsed.get(f, {}).get("output", []):
            for n in o:
                if n != "__is_block__": mo[mod].add(clean(n))
called = {}
for m in parsed["main.tf"].get("module", []):
    for name, body in m.items():
        if name == "__is_block__": continue
        name, src = clean(name), clean(body["source"]).replace("./modules/", "")
        args = {clean(k) for k in body if k not in ("source", "__is_block__")}
        called[name] = src
        miss = mv.get(src, set()) - args - md.get(src, set())
        extra = args - mv.get(src, set())
        if miss: errors.append(f"MODULE {name}: missing {miss}")
        if extra: errors.append(f"MODULE {name}: unknown {extra}")
for f in ["main.tf", "outputs.tf"]:
    for mref, out in set(re.findall(r"module\.(\w+)\.(\w+)", open(f).read())):
        if mref not in called: errors.append(f"{f}: undefined module {mref}")
        elif out not in mo.get(called[mref], set()): errors.append(f"{f}: module.{mref}.{out} undefined")
rv = set()
for v in parsed["variables.tf"].get("variable", []):
    rv.update(clean(k) for k in v if k != "__is_block__")
for f in ["main.tf", "outputs.tf"]:
    for var in set(re.findall(r"var\.(\w+)", open(f).read())):
        if var not in rv: errors.append(f"{f}: var.{var} undeclared")
for mod in mv:
    for f in glob.glob(f"modules/{mod}/*.tf"):
        for var in set(re.findall(r"var\.(\w+)", open(f).read())):
            if var not in mv[mod]: errors.append(f"{f}: var.{var} undeclared")
if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"{len(parsed)} tf files consistent")
