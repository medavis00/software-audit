#!/usr/bin/env python3
"""
audit.py - compares the inventories in ./inventories against your lists.

  python3 audit.py              # writes report.html and report.csv
  python3 audit.py --suggest    # also writes suggested-apps.csv: apps on 2+
                                # machines that aren't in either list yet

Uses only the Python standard library.
"""
import csv
import fnmatch
import html
import json
import re
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
INV_DIR = HERE / "inventories"

OK, BEHIND, NEWER, MISSING, REMOVE, WRONG, NA = "OK", "BEHIND", "NEWER", "MISSING", "REMOVE", "WRONG", "-"
PROBLEMS = (BEHIND, MISSING, REMOVE, WRONG)


def version_key(v):
    """Split '1.10.2-beta' into comparable parts so 1.10 > 1.9."""
    parts = [p for p in re.split(r"[^0-9A-Za-z]+", v or "") if p]
    key = [(0, int(p), "") if p.isdigit() else (1, 0, p.lower()) for p in parts]
    while key and key[-1] == (0, 0, ""):  # 24.0 == 24.0.0
        key.pop()
    return key


def read_csv(name):
    path = HERE / name
    if not path.exists():
        return []
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = []
        for row in csv.DictReader(f):
            row = {(k or "").strip().lower(): (v or "").strip() for k, v in row.items()}
            if row.get("app") and not row["app"].startswith("#"):
                rows.append(row)
        return rows


def patterns(row):
    pats = [p.strip() for p in row.get("match", "").split(";") if p.strip()]
    return [p.lower() for p in (pats or [row["app"]])]


def find(apps, pats):
    """Installed apps whose name matches any pattern (case-insensitive, * wildcards)."""
    return [a for a in apps if any(fnmatch.fnmatchcase(a["name"].lower(), p) for p in pats)]


def load_inventories():
    machines = []
    for path in sorted(INV_DIR.glob("*.json")):
        with open(path, encoding="utf-8-sig") as f:
            data = json.load(f)
        apps = data.get("apps") or []
        if isinstance(apps, dict):  # PowerShell turns a 1-item array into an object
            apps = [apps]
        data["apps"] = [a for a in apps if a.get("name")]
        machines.append(data)
    return machines


def audit(machines, approved, deprecated):
    hosts = [m["hostname"] for m in machines]
    results = []  # (section, app, expected, {host: (status, version)}, note)

    for row in approved:
        pats = patterns(row)
        scope = {h.strip().lower() for h in row.get("machines", "").split(";") if h.strip()}
        found = {}
        for m in machines:
            hits = find(m["apps"], pats)
            if hits:
                found[m["hostname"]] = max((a.get("version", "") for a in hits), key=version_key)

        expected = row.get("expected_version", "")
        minimum = expected.startswith(">=")
        is_value = expected.lower().startswith("equals:")
        if expected.lower() == "any" or is_value:
            # "any": just has to be installed. "equals:text": value must match exactly
            # (used for settings such as git-config entries). Not "=text", which Excel
            # would turn into a formula.
            want = expected[7:].strip().lower() if is_value else None
            cells = {}
            for h in hosts:
                if scope and h.lower() not in scope:
                    cells[h] = (NA, "")
                elif h not in found:
                    cells[h] = (MISSING, "")
                else:
                    cells[h] = (OK if want is None or found[h].lower() == want else WRONG, found[h])
            results.append(("Approved", row["app"], expected, cells, row.get("notes", "")))
            continue
        if minimum:
            target = expected[2:].strip()
        elif expected and expected.lower() != "latest":
            target = expected
        else:  # blank / latest: everyone should match the newest copy found
            target = max(found.values(), key=version_key) if found else ""
            expected = f"newest found ({target})" if target else "newest found"

        cells = {}
        for h in hosts:
            if scope and h.lower() not in scope:
                cells[h] = (NA, "")
            elif h not in found:
                cells[h] = (MISSING, "")
            else:
                v = found[h]
                cmp = (version_key(v) > version_key(target)) - (version_key(v) < version_key(target))
                if cmp < 0:
                    cells[h] = (BEHIND, v)
                elif cmp > 0 and not minimum:
                    cells[h] = (NEWER, v)
                else:
                    cells[h] = (OK, v)
        results.append(("Approved", row["app"], expected, cells, row.get("notes", "")))

    for row in deprecated:
        pats = patterns(row)
        cells = {}
        for m in machines:
            hits = find(m["apps"], pats)
            if hits:
                cells[m["hostname"]] = (REMOVE, ", ".join(sorted({a.get("version") or "?" for a in hits})))
            else:
                cells[m["hostname"]] = (OK, "")
        results.append(("Deprecated", row["app"], "not installed", cells, row.get("reason", "")))

    return hosts, results


def unlisted(machines, approved, deprecated):
    """Apps found on machines that no list mentions, keyed by name."""
    all_pats = [p for row in approved + deprecated for p in patterns(row)]
    seen = {}
    for m in machines:
        for a in m["apps"]:
            n = a["name"].lower()
            if any(fnmatch.fnmatchcase(n, p) for p in all_pats):
                continue
            entry = seen.setdefault(n, {"name": a["name"], "hosts": {}})
            entry["hosts"][m["hostname"]] = a.get("version", "")
    return sorted(seen.values(), key=lambda e: (-len(e["hosts"]), e["name"].lower()))


def write_csv(hosts, results, path):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["list", "app", "expected", "machine", "status", "installed_version", "notes"])
        for section, app, expected, cells, note in results:
            for h in hosts:
                status, ver = cells[h]
                w.writerow([section, app, expected, h, status, ver, note])


COLORS = {OK: "ok", BEHIND: "bad", MISSING: "warn", REMOVE: "bad", WRONG: "bad", NEWER: "info", NA: "na"}


def write_html(machines, hosts, results, extra, path):
    e = html.escape
    issues = sum(1 for _, _, _, c, _ in results for s, _ in c.values() if s in PROBLEMS)
    out = [f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Software audit</title><style>
body{{font:14px system-ui,sans-serif;margin:24px;color:#222;background:#fff}}
h1{{margin:0 0 4px}} .sub{{color:#666;margin-bottom:20px}}
table{{border-collapse:collapse;margin:8px 0 24px;width:100%}}
th,td{{border:1px solid #ddd;padding:6px 8px;text-align:left;vertical-align:top}}
th{{background:#f4f4f4}} td.note{{color:#666;font-size:12px}}
.ok{{background:#e6f4ea}} .bad{{background:#fce8e6;font-weight:600}}
.warn{{background:#fef7e0}} .info{{background:#e8f0fe}} .na{{color:#aaa}}
.wrap{{overflow-x:auto}} details summary{{cursor:pointer;font-weight:600;margin:8px 0}}
</style></head><body>
<h1>Software audit</h1>
<div class="sub">{datetime.now():%Y-%m-%d %H:%M} &middot; {len(hosts)} machines &middot;
<b>{issues} issue(s)</b> (behind, missing, wrong setting, or should be removed)</div>
<table><tr><th>Machine</th><th>OS</th><th>Inventory taken</th><th>Apps found</th></tr>"""]
    for m in machines:
        out.append(f"<tr><td>{e(m['hostname'])}</td><td>{e(m.get('os', ''))}</td>"
                   f"<td>{e(m.get('collected_at', ''))}</td><td>{len(m['apps'])}</td></tr>")
    out.append("</table>")

    for section in ("Approved", "Deprecated"):
        rows = [r for r in results if r[0] == section]
        if not rows:
            continue
        title = "Approved apps" if section == "Approved" else "Deprecated apps (should be removed)"
        out.append(f"<h2>{title}</h2><div class='wrap'><table><tr><th>App</th><th>Expected</th>")
        out += [f"<th>{e(h)}</th>" for h in hosts]
        out.append("<th>Notes</th></tr>")
        for _, app, expected, cells, note in rows:
            out.append(f"<tr><td>{e(app)}</td><td>{e(expected)}</td>")
            for h in hosts:
                s, v = cells[h]
                label = f"{e(v)}<br><small>{s}</small>" if v else s
                out.append(f"<td class='{COLORS[s]}'>{label}</td>")
            out.append(f"<td class='note'>{e(note)}</td></tr>")
        out.append("</table></div>")

    out.append(f"<details><summary>Apps not on either list ({len(extra)}), "
               "most common first</summary><div class='wrap'><table><tr><th>App</th>")
    out += [f"<th>{e(h)}</th>" for h in hosts]
    out.append("</tr>")
    for x in extra:
        out.append(f"<tr><td>{e(x['name'])}</td>")
        out += [f"<td>{e(x['hosts'][h]) if h in x['hosts'] else ''}</td>" for h in hosts]
        out.append("</tr>")
    out.append("</table></div></details></body></html>")
    path.write_text("\n".join(out), encoding="utf-8")
    return issues


def main():
    machines = load_inventories()
    if not machines:
        sys.exit(f"No inventories found in {INV_DIR}. Run the collect script on each computer first.")
    approved, deprecated = read_csv("approved-apps.csv"), read_csv("deprecated-apps.csv")
    hosts, results = audit(machines, approved, deprecated)
    extra = unlisted(machines, approved, deprecated)

    write_csv(hosts, results, HERE / "report.csv")
    issues = write_html(machines, hosts, results, extra, HERE / "report.html")

    for section, app, _, cells, _ in results:
        for h in hosts:
            s, v = cells[h]
            if s in PROBLEMS:
                print(f"  {s:8} {app} on {h}" + (f" ({v})" if v else ""))
    print(f"\n{issues} issue(s) across {len(hosts)} machines. Open report.html for the full picture.")

    if "--suggest" in sys.argv:
        common = [x for x in extra if len(x["hosts"]) >= 2]
        with open(HERE / "suggested-apps.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["app", "match", "expected_version", "machines", "notes"])
            for x in common:
                w.writerow([x["name"], "", "latest", "", "on " + ", ".join(sorted(x["hosts"]))])
        print(f"Wrote suggested-apps.csv with {len(common)} apps found on 2+ machines. "
              "Copy the rows you want into approved-apps.csv.")


if __name__ == "__main__":
    main()
