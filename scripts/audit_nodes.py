#!/usr/bin/env python3
"""Audit all catalog nodes for frontend/backend consistency."""

import re, os, glob

catalog = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "catalog")
issues = []

for fe_path in sorted(glob.glob(os.path.join(catalog, "**", "frontend.ts"), recursive=True)):
    dir_path = os.path.dirname(fe_path)
    be_path = os.path.join(dir_path, "backend.rs")
    node = fe_path.replace(catalog + "/", "").replace("/frontend.ts", "")

    with open(fe_path) as fh:
        fe = fh.read()

    has_backend = os.path.exists(be_path)
    if not has_backend:
        # Layout nodes (annotation, group) don't need backends
        if "layout" not in node:
            issues.append(f"NO_BACKEND: {node}")
        continue

    with open(be_path) as fh:
        be = fh.read()

    # --- Extract FE type ---
    fe_type_m = re.search(r"type:\s*'([^']+)'", fe)
    fe_type = fe_type_m.group(1) if fe_type_m else "???"

    # --- Extract BE type ---
    be_type_m = re.search(r'fn node_type.*?\n\s*"([^"]+)"', be, re.DOTALL)
    be_type = be_type_m.group(1) if be_type_m else "???"

    if fe_type != be_type:
        issues.append(f"TYPE_MISMATCH: {node} -> FE:{fe_type} BE:{be_type}")

    def extract_bracket_content(text, keyword):
        """Extract content of [...] after keyword, handling nested brackets."""
        idx = text.find(keyword)
        if idx == -1:
            return None
        start = text.find('[', idx)
        if start == -1:
            return None
        depth = 0
        for i in range(start, len(text)):
            if text[i] == '[':
                depth += 1
            elif text[i] == ']':
                depth -= 1
                if depth == 0:
                    return text[start+1:i]
        return None

    # --- Extract FE inputs ---
    inputs_content = extract_bracket_content(fe, 'defaultInputs')
    fe_inputs = re.findall(r"name:\s*'([^']+)'", inputs_content) if inputs_content else []

    # --- Extract FE outputs ---
    outputs_content = extract_bracket_content(fe, 'defaultOutputs')
    fe_outputs = re.findall(r"name:\s*'([^']+)'", outputs_content) if outputs_content else []

    # --- Extract FE required inputs ---
    fe_required = set()
    if inputs_content:
        for block in re.findall(r"\{[^}]+\}", inputs_content):
            nm = re.search(r"name:\s*'([^']+)'", block)
            rq = re.search(r"required:\s*(true|false)", block)
            if nm and rq and rq.group(1) == "true":
                fe_required.add(nm.group(1))

    # --- Extract BE inputs ---
    be_m = re.search(r"inputs:\s*vec!\[(.*?)\],\s*outputs:", be, re.DOTALL)
    be_inputs = re.findall(r'name:\s*"([^"]+)"', be_m.group(1)) if be_m else []

    # --- Extract BE outputs ---
    be_m2 = re.search(r"outputs:\s*vec!\[(.*?)\]", be, re.DOTALL)
    be_outputs = re.findall(r'name:\s*"([^"]+)"', be_m2.group(1)) if be_m2 else []

    # --- Check input port name mismatches ---
    if fe_inputs != be_inputs:
        issues.append(f"INPUT_MISMATCH: {node}")
        issues.append(f"  FE: {fe_inputs}")
        issues.append(f"  BE: {be_inputs}")

    # --- Check output port name mismatches ---
    if fe_outputs != be_outputs:
        issues.append(f"OUTPUT_MISMATCH: {node}")
        issues.append(f"  FE: {fe_outputs}")
        issues.append(f"  BE: {be_outputs}")

    # --- Check validation coverage ---
    validated = set(re.findall(r"isInputConnected\('([^']+)'", fe))
    config_validated = set(re.findall(r"hasConfigValue\('([^']+)'", fe))
    missing = fe_required - validated - config_validated
    if missing:
        issues.append(f"MISSING_VALIDATION: {node} -> required but not validated: {missing}")

    # --- Check that validated ports actually exist in inputs ---
    fe_input_set = set(fe_inputs)
    phantom_validated = validated - fe_input_set
    if phantom_validated:
        issues.append(f"PHANTOM_VALIDATION: {node} -> validates non-existent inputs: {phantom_validated}")

    # --- Check BE required vs FE required ---
    be_required = set()
    if be_m:
        for block in re.findall(r"PortDef\s*\{[^}]+\}", be_m.group(1)):
            nm = re.search(r'name:\s*"([^"]+)"', block)
            rq = re.search(r"required:\s*(true|false)", block)
            if nm and rq and rq.group(1) == "true":
                be_required.add(nm.group(1))

    fe_only_req = fe_required - be_required
    be_only_req = be_required - fe_required
    if fe_only_req:
        issues.append(f"REQUIRED_FE_ONLY: {node} -> required in FE but not BE: {fe_only_req}")
    if be_only_req:
        issues.append(f"REQUIRED_BE_ONLY: {node} -> required in BE but not FE: {be_only_req}")

print(f"Audited {len(list(glob.glob(os.path.join(catalog, '**', 'frontend.ts'), recursive=True)))} nodes\n")

if issues:
    print(f"Found {len(issues)} issues:\n")
    for i in issues:
        print(i)
else:
    print("ALL NODES OK - no mismatches found")
