#!/usr/bin/env python3
"""Check every PrometheusRule in the repo with promtool.

The operator's webhook rejects a rule that does not parse, but only once Flux
applies it, and then the whole monitoring Kustomization stalls. This catches it
at push. Usage: check-rules.py [promtool]
"""
import glob
import subprocess
import sys
import tempfile

import yaml

promtool = sys.argv[1] if len(sys.argv) > 1 else "promtool"
files = []
for path in sorted(glob.glob("kubernetes/**/*.yaml", recursive=True)):
    with open(path) as f:
        for doc in yaml.safe_load_all(f):
            if isinstance(doc, dict) and doc.get("kind") == "PrometheusRule":
                tmp = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
                yaml.safe_dump(doc["spec"], tmp)
                tmp.close()
                files.append(tmp.name)
                print(f"{path}: {doc['metadata']['name']}")
if not files:
    sys.exit("no PrometheusRule found")
sys.exit(subprocess.run([promtool, "check", "rules", *files]).returncode)
