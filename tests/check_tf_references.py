"""Every Terraform reference must resolve to something that exists.

Catches the class of bug where an edit deletes a resource but leaves the
outputs, variables or other resources pointing at it. `terraform validate`
finds this instantly, but there is no terraform binary in CI, so this is a
static stand-in.

A real instance: rewriting modules/irsa/main.tf truncated the file and
silently removed aws_iam_role.alb_controller while outputs.tf still exported
its ARN. Nothing else in the suite noticed.
"""
import os
import re
import sys

os.chdir(os.path.join(os.path.dirname(__file__), ".."))

RESOURCE_RE = re.compile(r'^resource\s+"([\w]+)"\s+"([\w]+)"', re.M)
DATA_RE = re.compile(r'^data\s+"([\w]+)"\s+"([\w]+)"', re.M)
VARIABLE_RE = re.compile(r'^variable\s+"([\w]+)"', re.M)
MODULE_RE = re.compile(r'^module\s+"([\w]+)"', re.M)
OUTPUT_RE = re.compile(r'^output\s+"([\w]+)"', re.M)

fails = []


def module_dirs():
    yield "terraform"
    base = "terraform/modules"
    for d in sorted(os.listdir(base)):
        if os.path.isdir(os.path.join(base, d)):
            yield os.path.join(base, d)


for mod in module_dirs():
    files = [os.path.join(mod, f) for f in os.listdir(mod) if f.endswith(".tf")]
    body = "\n".join(open(f).read() for f in files)

    resources = {f"{t}.{n}" for t, n in RESOURCE_RE.findall(body)}
    datas = {f"data.{t}.{n}" for t, n in DATA_RE.findall(body)}
    variables = set(VARIABLE_RE.findall(body))
    modules = set(MODULE_RE.findall(body))

    # 1. every referenced resource must be declared in this module
    for ref in set(re.findall(r'(?<![\w.])(aws_[\w]+)\.([\w]+)\.', body)):
        name = f"{ref[0]}.{ref[1]}"
        if name not in resources and f"data.{name}" not in datas:
            fails.append(f"{mod}: references {name} which is not declared here")

    # 2. every referenced data source must be declared
    for t, n in set(re.findall(r'data\.(aws_[\w]+)\.([\w]+)\.', body)):
        if f"data.{t}.{n}" not in datas:
            fails.append(f"{mod}: references data.{t}.{n} which is not declared")

    # 3. every var.X must have a variable block
    for v in set(re.findall(r'(?<![\w.])var\.([\w]+)', body)):
        if v not in variables:
            fails.append(f"{mod}: uses var.{v} but no variable block declares it")

    # 4. every module.X must exist (root module only)
    for m in set(re.findall(r'(?<![\w.])module\.([\w]+)\.', body)):
        if m not in modules:
            fails.append(f"{mod}: references module.{m} which is not declared")

    # 5. every file() path must exist
    for path in re.findall(r'file\("\$\{path\.module\}/([^"]+)"\)', body):
        if not os.path.exists(os.path.join(mod, path)):
            fails.append(f"{mod}: file() points at missing {path}")

# 6. root outputs must reference outputs the child modules actually declare
root = "\n".join(
    open(os.path.join("terraform", f)).read()
    for f in os.listdir("terraform") if f.endswith(".tf")
)
for child, attr in set(re.findall(r'module\.(\w+)\.(\w+)', root)):
    child_dir = os.path.join("terraform/modules", child)
    if not os.path.isdir(child_dir):
        continue
    child_body = "\n".join(
        open(os.path.join(child_dir, f)).read()
        for f in os.listdir(child_dir) if f.endswith(".tf")
    )
    if attr not in set(OUTPUT_RE.findall(child_body)):
        fails.append(f"root: uses module.{child}.{attr} but that module has no such output")

if fails:
    print("\n".join(sorted(set(fails))))
    sys.exit(1)
print("all Terraform references resolve")
