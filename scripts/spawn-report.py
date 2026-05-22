#!/usr/bin/env python3
"""Spawn-pattern report from the SpawnTracker SQLite DB (--spawn-db).

Mines the logged spawn history for the patterns MySEQ's spawn list surfaces,
but computed offline over the whole capture (more robust than live
position-keyed matching, which is fuzzy because we only see packets):
  - learned respawn intervals per mob (death/disappearance -> reappearance)
  - busiest spawn locations
  - kill leaderboard (who killed what)

Usage:  python3 spawn-report.py [path-to-eq-spawns.db]
Default DB path: /home/delyosius/eq-spawns.db
"""
import sqlite3, sys
from collections import defaultdict, Counter

DB = sys.argv[1] if len(sys.argv) > 1 else "/home/delyosius/eq-spawns.db"
c = sqlite3.connect(DB)

def trim(n):  # group a base name (strip trailing spawn-number digits)
    return n.rstrip("0123456789")

# first observed position per instance = best estimate of its spawn location
loc = {}
for iid, x, y, z in c.execute(
    "SELECT instance_id,x,y,z FROM positions p "
    "WHERE ts=(SELECT MIN(ts) FROM positions WHERE instance_id=p.instance_id)"):
    loc[iid] = (x, y, z)

rows = list(c.execute(
    "SELECT instance_id,name,first_seen,end_event,end_time FROM spawns ORDER BY first_seen"))

def near(a, b, tol=40):
    return a and b and abs(a[0]-b[0]) < tol and abs(a[1]-b[1]) < tol

# ---- respawn intervals -------------------------------------------------
by_base = defaultdict(list)
for r in rows:
    by_base[trim(r[1])].append(r)

intervals = defaultdict(list)
for base, lst in by_base.items():
    for i, (iid, name, fs, ee, et) in enumerate(lst):
        ref = et if et else fs  # death time if known, else first-seen as proxy
        if not et:
            continue
        for s in lst[i+1:]:
            if s[2] > ref and near(loc.get(iid), loc.get(s[0])):
                intervals[base].append((s[2]-ref)/1000.0)
                break

print("== RESPAWN TIMERS (base name: samples, median sec, min-max) ==")
def med(v): v=sorted(v); n=len(v); return v[n//2] if n%2 else (v[n//2-1]+v[n//2])/2
for base in sorted(intervals, key=lambda b:-len(intervals[b])):
    v=[x for x in intervals[base] if 5 < x < 3600]
    if len(v) >= 2:
        print(f"  {base:30s} n={len(v):3d}  ~{med(v):4.0f}s ({med(v)/60:.1f}m)  [{min(v):.0f}-{max(v):.0f}]")

# ---- busiest locations -------------------------------------------------
print("\n== TOP SPAWN LOCATIONS (snap-32 grid: sightings, names) ==")
cell = defaultdict(Counter)
for iid, name, *_ in rows:
    p = loc.get(iid)
    if not p: continue
    k = (round(p[0]/32)*32, round(p[1]/32)*32)
    cell[k][trim(name)] += 1
for k in sorted(cell, key=lambda k:-sum(cell[k].values()))[:15]:
    tot=sum(cell[k].values()); names=", ".join(f"{n}x{c}" for n,c in cell[k].most_common(3))
    print(f"  ({k[0]:6d},{k[1]:6d})  {tot:3d}  {names}")

# ---- kill leaderboard --------------------------------------------------
print("\n== KILLS BY KILLER (killer_id: kills) ==")
for kid, n in c.execute(
    "SELECT killer_id, count(*) FROM spawns WHERE end_event='killed' "
    "GROUP BY killer_id ORDER BY 2 DESC LIMIT 10"):
    print(f"  killer {kid}: {n}")

print("\n== TOTALS ==")
g=lambda q:c.execute(q).fetchone()[0]
nspawn=g("SELECT count(*) FROM spawns")
npos=g("SELECT count(*) FROM positions")
nkill=g("SELECT count(*) FROM spawns WHERE end_event='killed'")
print(f"  spawns={nspawn}  positions={npos}  killed={nkill}")
