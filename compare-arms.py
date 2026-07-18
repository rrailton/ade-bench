#!/usr/bin/env python3
"""Compare two (or more) benchmark arms from ade-bench results TSVs.

Usage: ./compare-arms.py <arm-prefix> <arm-prefix> [...]
  e.g. ./compare-arms.py fable5-low__2026-07-17 opus48-xhigh__2026-07-17

An arm prefix matches experiments/<prefix>*/results.tsv (all batches).
If a task appears multiple times in an arm (multiple attempts), pass@1 is
the mean of its attempts.
"""

import csv
import glob
import sys
from collections import defaultdict


def load_arm(prefix: str) -> dict[str, list[dict]]:
    trials: dict[str, list[dict]] = defaultdict(list)
    files = glob.glob(f"experiments/{prefix}*/results.tsv")
    if not files:
        sys.exit(f"ERROR: no results.tsv under experiments/{prefix}*")
    for f in files:
        with open(f) as fh:
            for row in csv.DictReader(fh, delimiter="\t"):
                trials[row["task_id"]].append(row)
    return trials


def fnum(row, key):
    try:
        return float(row[key] or 0)
    except ValueError:
        return 0.0


def summarize(name: str, trials: dict[str, list[dict]]) -> dict:
    rows = [r for rs in trials.values() for r in rs]
    n = len(rows)
    passes = sum(1 for r in rows if r["result"] == "pass")
    timeouts = sum(1 for r in rows if "timeout" in (r["failure_type"] or ""))
    errors = sum(1 for r in rows if r["result"] == "ERROR")
    return {
        "name": name,
        "trials": n,
        "tasks": len(trials),
        "pass": passes,
        "pass_rate": passes / n if n else 0,
        "timeouts": timeouts,
        "errors": errors,
        "avg_time_s": sum(fnum(r, "time_seconds") for r in rows) / n if n else 0,
        "tot_out_tok": int(sum(fnum(r, "output_tokens") for r in rows)),
        "tot_cost": sum(fnum(r, "cost") for r in rows),
        "avg_test_pct": sum(fnum(r, "passed_percentage") for r in rows) / n if n else 0,
    }


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    arms = {p: load_arm(p) for p in sys.argv[1:]}
    sums = [summarize(p, t) for p, t in arms.items()]

    hdr = f"{'metric':<22}" + "".join(f"{s['name'][:28]:>30}" for s in sums)
    print(hdr)
    print("-" * len(hdr))
    for key, fmt in [
        ("trials", "d"),
        ("tasks", "d"),
        ("pass", "d"),
        ("pass_rate", ".1%"),
        ("avg_test_pct", ".1f"),
        ("timeouts", "d"),
        ("errors", "d"),
        ("avg_time_s", ".0f"),
        ("tot_out_tok", ","),
        ("tot_cost", ",.2f"),
    ]:
        print(f"{key:<22}" + "".join(f"{s[key]:>30{fmt}}" for s in sums))

    # Head-to-head on shared tasks (first two arms), pass@1 as attempt mean
    a, b = sys.argv[1], sys.argv[2]
    shared = sorted(set(arms[a]) & set(arms[b]))
    wins_a, wins_b, both_fail = [], [], []
    for t in shared:
        ra = sum(r["result"] == "pass" for r in arms[a][t]) / len(arms[a][t])
        rb = sum(r["result"] == "pass" for r in arms[b][t]) / len(arms[b][t])
        if ra > rb:
            wins_a.append(t)
        elif rb > ra:
            wins_b.append(t)
        elif ra == 0:
            both_fail.append(t)
    print(f"\nHead-to-head on {len(shared)} shared tasks:")
    print(f"  {a} better : {len(wins_a):>3}  {' '.join(wins_a)}")
    print(f"  {b} better : {len(wins_b):>3}  {' '.join(wins_b)}")
    print(f"  both fail : {len(both_fail):>3}  {' '.join(both_fail)}")
    d = len(wins_a) + len(wins_b)
    if d:
        # Two-sided sign test on discordant tasks (exact binomial)
        from math import comb

        k = max(len(wins_a), len(wins_b))
        p = sum(comb(d, i) for i in range(k, d + 1)) / 2**d * 2
        print(
            f"  sign test : p = {min(p, 1.0):.3f} "
            f"({'significant' if p < 0.05 else 'NOT significant'} at 0.05)"
        )


if __name__ == "__main__":
    main()
