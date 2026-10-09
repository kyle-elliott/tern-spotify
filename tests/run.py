"""Runs the Luau unit tests with the Luau CLI in .tools/.

tests/pure.luau runs as is. Tests whose name starts with `with_tern_` need the
modules to see a fake `tern` global, which the CLI can't inject (each required
module gets its own read-only global environment). For those, this script
bundles tests/fake_tern.luau, every lib/*.luau module and the test into one
chunk where `tern` and `require` are locals.

    python tests/run.py
"""

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LUAU = ROOT / ".tools" / ("luau.exe" if sys.platform == "win32" else "luau")

# Modules in dependency order.
MODULES = ["config", "text", "proc", "sha256", "url", "field", "model", "vault", "auth", "api", "session"]
# Test helpers bundled the same way (from tests/).
TEST_MODULES = ["check"]


def module_body(name: str) -> str:
    src = (ROOT / "lib" / f"{name}.luau").read_text(encoding="utf-8")
    src = re.sub(r"^--!strict\s*$", "", src, flags=re.M)
    # `export type` is only legal at a chunk's top level.
    return re.sub(r"^export type ", "type ", src, flags=re.M)


def bundle(test: pathlib.Path) -> str:
    parts = [
        "local tern = (function()",
        (ROOT / "tests" / "fake_tern.luau").read_text(encoding="utf-8"),
        "end)()",
        "local __modules = {}",
        "local function require(path)",
        "  local name = string.match(path, '([%w_]+)$')",
        "  local m = __modules[name]",
        "  if m == nil then error('module not bundled: ' .. path) end",
        "  return m",
        "end",
    ]
    for name in TEST_MODULES:
        body = (ROOT / "tests" / f"{name}.luau").read_text(encoding="utf-8")
        parts.append(f"__modules[{name!r}] = (function()\n{body}\nend)()")
    for name in MODULES:
        parts.append(f"__modules[{name!r}] = (function()\n{module_body(name)}\nend)()")
    parts.append(test.read_text(encoding="utf-8"))
    return "\n".join(parts)


def run(path: pathlib.Path, source: str | None = None) -> bool:
    if source is None:
        cmd = [str(LUAU), str(path.relative_to(ROOT))]
        result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    else:
        with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False, encoding="utf-8") as f:
            f.write(source)
            tmp = f.name
        result = subprocess.run([str(LUAU), tmp], cwd=ROOT, capture_output=True, text=True)
        pathlib.Path(tmp).unlink()
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return result.returncode == 0


def main() -> int:
    ok = True
    for test in sorted((ROOT / "tests").glob("*.luau")):
        if test.name in ("fake_tern.luau", "check.luau"):
            continue
        if test.name.startswith("with_tern_"):
            ok &= run(test, bundle(test))
        else:
            ok &= run(test)
    print("ALL PASSED" if ok else "FAILURES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
