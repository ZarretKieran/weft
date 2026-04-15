#!/usr/bin/env python3
"""
Python code executor for WeaveMind Code node.

Isolation is handled externally by nsjail (on Linux) or skipped (on dev).
This script handles: dependency installation, variable injection, code execution.

Usage: python3 sandbox_runner.py <base64_code> <base64_input_json> <base64_deps_json>
"""

import sys
import os
import json
import base64
import subprocess
import re

# Packages pre-installed in the Docker image. Skip pip install for these.
PRE_INSTALLED = {
    "numpy", "pandas", "requests", "pillow", "pyyaml",
    "beautifulsoup4", "bs4", "lxml", "scipy", "scikit-learn",
    "matplotlib", "httpx", "aiohttp",
}

# Valid pip dependency: package name with optional version specifier, no flags or URLs
_VALID_DEP_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*(\[[a-zA-Z0-9,._-]+\])?\s*([<>=!~]+\s*[a-zA-Z0-9._*]+)?$')


def install_dependencies(deps: list[str]) -> None:
    """Install pip packages into /tmp/pip_packages. Skip pre-installed ones."""
    to_install = []
    for dep in deps:
        dep = dep.strip()
        if not dep:
            continue
        if not _VALID_DEP_RE.match(dep):
            raise RuntimeError(f"Invalid dependency format: {dep!r}")
        pkg_name = dep.split("==")[0].split(">=")[0].split("<=")[0].split("~=")[0].split("!=")[0].split("[")[0].strip().lower()
        if pkg_name not in PRE_INSTALLED:
            to_install.append(dep)
        else:
            print(f"PIP_SKIP: {dep} (pre-installed)", file=sys.stderr)

    if not to_install:
        return

    target_dir = "/tmp/pip_packages"
    print(f"PIP_INSTALL: {', '.join(to_install)}", file=sys.stderr)

    result = subprocess.run(
        ["/usr/bin/python3", "-m", "pip", "install", "--quiet", "--no-cache-dir", "--target", target_dir] + to_install,
        capture_output=True, text=True, timeout=120,
    )

    if result.returncode != 0:
        raise RuntimeError(f"pip install failed: {result.stderr.strip()}")

    sys.path.insert(0, target_dir)


def run_code(code: str, input_data: dict) -> dict:
    """Execute user code with input variables injected.

    The user's code is wrapped inside a function so that `return` works.
    Everything (imports, constants, classes, functions, logic) goes inside
    the wrapper. Python allows imports inside functions, so this is valid.

    The only exception is `from X import *` which Python 3 disallows in
    functions. We detect this and move it to module level.
    """
    exec_globals = {
        "__builtins__": __builtins__,
        "json": json,
    }
    for port_name, value in input_data.items():
        safe_name = sanitize_identifier(port_name)
        exec_globals[safe_name] = value

    # Extract `from X import *` lines (not allowed inside functions)
    star_imports, clean_code = extract_star_imports(code)

    wrapped_code = f"""{star_imports}
def __user_code__():
{indent_code(clean_code)}

__result__ = __user_code__()
"""

    exec(wrapped_code, exec_globals)

    result = exec_globals.get("__result__")

    if result is None:
        return {}
    if not isinstance(result, dict):
        raise ValueError(f"Code must return a dict with output port names as keys, got: {type(result)}")

    return result


def extract_star_imports(code: str) -> tuple[str, str]:
    """Extract `from X import *` lines (illegal inside functions).
    Returns (star_imports_str, remaining_code_str)."""
    star_imports = []
    remaining = []
    for line in code.split("\n"):
        if re.match(r'^\s*from\s+\S+\s+import\s+\*\s*$', line):
            star_imports.append(line.strip())
        else:
            remaining.append(line)
    return "\n".join(star_imports), "\n".join(remaining)


def sanitize_identifier(name: str) -> str:
    """Sanitize a string to be a valid Python identifier."""
    result = []
    for i, c in enumerate(name):
        if c.isalnum() or c == "_":
            if i == 0 and c.isdigit():
                result.append("_")
            result.append(c)
        else:
            result.append("_")
    return "".join(result) if result else "_input"


def indent_code(code: str, indent: str = "    ") -> str:
    return "\n".join(indent + line for line in code.split("\n"))


def main():
    if len(sys.argv) != 4:
        print("Usage: sandbox_runner.py <base64_code> <base64_input_json> <base64_deps_json>", file=sys.stderr)
        sys.exit(1)

    try:
        code = base64.b64decode(sys.argv[1]).decode("utf-8")
        input_json = base64.b64decode(sys.argv[2]).decode("utf-8")
        input_data = json.loads(input_json) if input_json else {}
        deps_json = base64.b64decode(sys.argv[3]).decode("utf-8")
        deps = json.loads(deps_json) if deps_json else []
    except Exception as e:
        print(f"ERROR: Failed to decode arguments: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        if deps:
            install_dependencies(deps)
    except Exception as e:
        print(f"ERROR: Dependency installation failed: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        result = run_code(code, input_data)
        print(json.dumps(result))
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
