import yaml, re, sys, glob, os
import kubernetes_validate
os.chdir(os.path.join(os.path.dirname(__file__), "..", "helm"))
def get(values, path):
    cur = values
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur: return None
        cur = cur[part]
    return cur
def render(tpl, values):
    # REVIEW FIX 4.4 — conditionals are tracked with a STACK, not a flat
    # depth counter plus a single `skip` flag. The old model only evaluated
    # the condition at depth 1, so an inner `if` nested inside the chart-wide
    # `{{- if .Values.ingress.enabled }}` was never evaluated at all and BOTH
    # branches were emitted. That produced invalid YAML for the HTTPS ingress
    # and would have silently mis-rendered any future nested conditional.
    out, stack, lines, i = [], [], tpl.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        mif = re.match(r"\s*\{\{-? if (?:\.Values\.)([\w.]+) \}\}", line)
        mend = re.match(r"\s*\{\{-? end \}\}", line)
        # REVIEW FIX 4.4 — {{- else }} support. helm/frontend/templates/
        # ingress.yaml needs it to emit HTTPS annotations when a certificate is
        # configured and plain HTTP when it is not. Without this the renderer
        # emitted BOTH branches and produced invalid YAML.
        melse = re.match(r"\s*\{\{-? else \}\}", line)
        mrange = re.match(r"(\s*)\{\{-? range \$key, \$val := \.Values\.([\w.]+) \}\}", line)
        # REVIEW FIX 4.6 — list ranges, e.g. {{- range .Values.a.b }} ... {{ . }}
        mrangelist = re.match(r"(\s*)\{\{-? range \.Values\.([\w.]+) \}\}", line)
        if mif:
            stack.append(bool(get(values, mif.group(1))))
            i += 1; continue
        if mend:
            if stack: stack.pop()
            i += 1; continue
        if melse:
            if stack: stack[-1] = not stack[-1]
            i += 1; continue
        if not all(stack): i += 1; continue
        if mrangelist:
            path, body = mrangelist.group(2), []
            i += 1
            while not re.match(r"\s*\{\{-? end \}\}", lines[i]):
                body.append(lines[i]); i += 1
            i += 1
            for item in (get(values, path) or []):
                for b in body:
                    out.append(b.replace("{{ . }}", str(item)))
            continue
        if mrange:
            path, body = mrange.group(2), []
            i += 1
            while not re.match(r"\s*\{\{-? end \}\}", lines[i]):
                body.append(lines[i]); i += 1
            i += 1
            for k, v in (get(values, path) or {}).items():
                for b in body:
                    out.append(b.replace("{{ $key }}", str(k)).replace("{{ $val | quote }}", chr(34)+str(v)+chr(34)))
            continue
        line = re.sub(r"\{\{ include \(print \$\.Template\.BasePath .*?\| sha256sum \}\}", "dummychecksum", line)
        line = re.sub(r"\{\{ \.Values\.([\w.]+) \}\}", lambda m: str(get(values, m.group(1)) or ""), line)
        out.append(line); i += 1
    return "\n".join(out)
errors, count = [], 0
for chart in ["backend", "worker", "frontend"]:
    values = yaml.safe_load(open(f"{chart}/values.yaml"))
    values["image"]["registry"] = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    if values.get("serviceAccount", {}).get("roleArn") == "" and chart != "frontend":
        values["serviceAccount"]["roleArn"] = "arn:aws:iam::123456789012:role/test"
    for k in values.get("config", {}):
        if values["config"][k] == "": values["config"][k] = "test-value"
    for t in sorted(glob.glob(f"{chart}/templates/*.yaml")):
        rendered = render(open(t).read(), values)
        if not rendered.strip(): continue
        docs = [d for d in yaml.safe_load_all(rendered) if d]
        for d in docs:
            count += 1
            try: kubernetes_validate.validate(d, "1.35", strict=True)
            except Exception as e: errors.append(f"{t}: {e}")
if errors:
    print("\n".join(errors)); sys.exit(1)
print(f"{count} manifests valid (K8s 1.35 strict)")
