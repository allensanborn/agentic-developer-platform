"""Verify or refresh boundary_register.yaml (format boundary-register/1, from wandercom/pact).

    python tools/boundary/boundary.py verify    # exit 1 on any mismatch, stale record or bad line
    python tools/boundary/boundary.py refresh   # re-cite every record from its own path, line and value

verify is what `dagger call check` runs; it prints the same result as `pact boundary verify`.
refresh rewrites only the sha256 of each record, after re-confirming the value is still a token
on the cited line (pact's cite_record). It refuses, writing nothing, if any value moved or
changed: fix the line number, or the identifier, by hand. A denies record (relation: absent)
is hashed and then checked by verify for the subject's absence from the whole file.
"""

import hashlib
import sys
from pathlib import Path

import yaml

from boundary_register import REGISTER_FILENAME, CiteError, cite_record, load_register, verify_entries

HEADER = "# Generated records: edit ids, values, paths and lines; then run\n#   python tools/boundary/boundary.py refresh\n# Never hand-edit a sha256. See docs/boundary-register.md.\n"


def verify(root: Path) -> int:
    entries, errors = load_register(root)
    errors += verify_entries(entries, root)
    if errors:
        print(f"Boundary register FAILED: {len(errors)} error(s) across {len(entries)} entries")
        for error in errors:
            print(f"  - {error}")
        return 1
    print(f"Boundary register PASSED: {len(entries)} entries verified against records")
    return 0


def refresh(root: Path) -> int:
    data = yaml.safe_load((root / REGISTER_FILENAME).read_text())
    failed = []
    for entry in data["entries"]:
        for side in entry["sides"]:
            for rec in side["records"]:
                if side["role"] == "denies":  # absence is checked by verify; just hash the file
                    rec["sha256"] = hashlib.sha256((root / rec["path"]).read_bytes()).hexdigest()
                    continue
                try:
                    rec.update(cite_record(root, kind="file", path=rec["path"], value=side["value"], line=rec["line"]))
                except CiteError as exc:
                    failed.append(f"{entry['id']} ({side['party']}): {exc}")
    if failed:
        print("Refusing to refresh:", *failed, sep="\n  - ")
        return 1
    body = yaml.safe_dump(data, sort_keys=False, width=200)
    (root / REGISTER_FILENAME).write_text(HEADER + body)
    return verify(root)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    root = Path(sys.argv[2] if len(sys.argv) > 2 else ".").resolve()
    if command not in ("verify", "refresh"):
        sys.exit(__doc__)
    sys.exit(verify(root) if command == "verify" else refresh(root))
