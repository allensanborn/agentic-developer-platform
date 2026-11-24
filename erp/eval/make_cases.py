"""Write cases.json: the seeded discrepancies the eval scores (ADR 0011).

Each case is the context the diagnosis graph would gather for one invoice (graph.gather),
with exactly one value changed, and the one fix that undoes it. As in the real data, the
invoice total keeps its value when a line is changed: that mismatch is what detection finds. Invoices are shaped like
Chinook's: 1 to 14 lines, unit prices 0.99 or 1.99, quantity 1. Seeded, so the file is the
same on every run; regenerate only to change the set on purpose:

    python3 erp/eval/make_cases.py > erp/eval/cases.json
"""

import json
import random

rng = random.Random(11)  # ADR 0011


def invoice(key: int, n_lines: int) -> dict:
    lines = []
    for i in range(n_lines):
        price = rng.choice([0.99, 1.99])
        lines.append({"invoice_line_id": key * 100 + i + 1, "track_id": rng.randint(1, 3503),
                      "unit_price": price, "quantity": 1, "track_unit_price": price, "line_total": price})
    total = round(sum(line["line_total"] for line in lines), 2)
    return {"invoice": [{"invoice_id": key, "total": total, "invoice_date": f"2025-{rng.randint(1, 12):02d}-{rng.randint(1, 28):02d}"}],
            "lines": lines}


def cases() -> list:
    out = []
    key = 400
    for kind in ["total", "price", "quantity"] * 4:  # four of each corruption
        key += 1
        ctx = invoice(key, rng.randint(2, 14) if kind != "total" else rng.randint(1, 14))
        lines, inv = ctx["lines"], ctx["invoice"][0]
        if kind == "total":
            inv["total"] = round(inv["total"] + rng.choice([5, 0.5, 2.97, -0.99]), 2)
            expect = {"kind": "fix", "fix_type": "set_invoice_total_from_lines", "params": {}}
        elif kind == "price":
            line = rng.choice(lines)
            line["unit_price"] = round(line["track_unit_price"] + rng.choice([1.0, 2.0, 0.5]), 2)
            line["line_total"] = round(line["unit_price"] * line["quantity"], 2)
            expect = {"kind": "fix", "fix_type": "set_line_price_from_track", "params": {"invoice_line_id": line["invoice_line_id"]}}
        else:
            line = rng.choice(lines)
            line["quantity"] = rng.choice([2, 3, 10])
            line["line_total"] = round(line["unit_price"] * line["quantity"], 2)
            expect = {"kind": "fix", "fix_type": "set_line_quantity",
                      "params": {"invoice_line_id": line["invoice_line_id"], "quantity": 1}}
        out.append({"id": f"{kind}-{key}", "rule": "invoice_total_mismatch", "key": key, "context": ctx, "expect": expect})
    return out


if __name__ == "__main__":
    print(json.dumps(cases(), indent=1))
