#!/usr/bin/env python3
"""Find post-patch OP_DeleteSpawn / OP_RemoveSpawn opcode IDs.

Cross-correlates the --list-events timeline against kill timestamps in the
SpawnTracker DB to find 4b or 5b S>C zone-unknown opcodes that fire inside
the corpse-decay window after each kill.

Target sizes / structs:
  4b = deleteSpawnStruct  {uint32 spawnId}
  5b = removeSpawnStruct  {uint32 spawnId, uint8 removeSpawn}

Corpse decay on Live: ~180s for trash NPCs, up to 600s for named.
Default window: +120s to +420s after kill (covers both).

Usage:
  python3 find-despawn-opcode.py \\
      --events /home/delyosius/showeq-events.log \\
      --db     /home/delyosius/eq-spawns.db \\
      [--decay-min 120] [--decay-max 420] \\
      [--since 60]        # only consider kills from the last N minutes

Then verify a STRONG candidate:
  1. Add  --dump-payload <opcode>:despawn.bin  to the daemon flags and rezone.
  2. Kill the same kind of mob; wait for decay.
  3. Run:  python3 find-despawn-opcode.py --verify despawn.bin \\
               --known-ids known_ids.txt
     where known_ids.txt has one dead spawn_id per line (from the DB or
     --dump-payload 1eb2:deaths.bin).
"""

import argparse, sqlite3, struct, sys
from collections import defaultdict, Counter

# ---------------------------------------------------------------------------

def load_kills(db_path, since_ms):
    db = sqlite3.connect(db_path)
    rows = db.execute(
        "SELECT spawn_id, end_time FROM spawns "
        "WHERE end_event='killed' AND end_time IS NOT NULL"
        + (" AND end_time >= ?" if since_ms else ""),
        (since_ms,) if since_ms else ()).fetchall()
    return rows  # [(spawn_id, end_time_ms), ...]


def parse_events(events_path, sizes=(4, 5)):
    """Yield (ts_ms, opcode_str, length) for S>C zone-unknown packets."""
    with open(events_path, errors='replace') as f:
        for line in f:
            parts = line.split()
            if len(parts) < 6:
                continue
            ts, dir_, opcode, length, stream, name = parts[:6]
            if dir_ != 'S' or stream != 'zone' or name != 'unknown':
                continue
            try:
                length = int(length)
                ts = int(ts)
            except ValueError:
                continue
            if length in sizes:
                yield ts, opcode, length


def correlate(events_path, kills, decay_lo, decay_hi):
    """Return per-opcode stats: total fires, fires inside any kill window."""
    # Build kill windows (ms)
    windows = [(t + decay_lo * 1000, t + decay_hi * 1000) for _, t in kills]

    total     = Counter()
    in_win    = Counter()
    hit_kills = defaultdict(set)   # opcode -> set of kill indices hit

    for ts, opcode, _length in parse_events(events_path):
        total[opcode] += 1
        for i, (wlo, whi) in enumerate(windows):
            if wlo <= ts <= whi:
                in_win[opcode] += 1
                hit_kills[opcode].add(i)

    return total, in_win, hit_kills


def verify_payloads(bin_path, known_ids):
    """
    Read a raw --dump-payload file and check how many packets have their
    first 4 bytes equal to a known dead spawn ID.

    dump-payload format: each record is prefixed with a 4-byte little-endian
    length, followed by that many bytes of payload (no timestamp).
    """
    hits = 0
    total = 0
    with open(bin_path, 'rb') as f:
        while True:
            hdr = f.read(4)
            if len(hdr) < 4:
                break
            plen, = struct.unpack_from('<I', hdr)
            payload = f.read(plen)
            if len(payload) < 4:
                continue
            total += 1
            sid, = struct.unpack_from('<I', payload, 0)
            if sid in known_ids:
                hits += 1
                flag = payload[4] if len(payload) >= 5 else None
                print(f"  MATCH  spawn_id={sid}"
                      + (f"  removeSpawn={flag}" if flag is not None else ""))
            else:
                sid_be, = struct.unpack_from('>I', payload, 0)
                print(f"  miss   raw={payload[:8].hex()}  LE={sid}  BE={sid_be}")
    print(f"\n{hits}/{total} payloads matched a known dead spawn ID.")


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--events',  help='path to --list-events log file')
    ap.add_argument('--db',      help='path to eq-spawns.db')
    ap.add_argument('--decay-min', type=int, default=120,
                    help='seconds after kill: window start (default 120)')
    ap.add_argument('--decay-max', type=int, default=420,
                    help='seconds after kill: window end (default 420)')
    ap.add_argument('--since',   type=int, default=0,
                    help='only use kills from the last N minutes (0=all)')
    ap.add_argument('--verify',  metavar='PAYLOAD_BIN',
                    help='verify a candidate: check raw dump-payload file')
    ap.add_argument('--known-ids', metavar='FILE',
                    help='newline-separated dead spawn IDs for --verify')
    args = ap.parse_args()

    # -- verify mode --
    if args.verify:
        if not args.known_ids:
            # fall back to DB if --db supplied
            if args.db:
                kills = load_kills(args.db, None)
                known = {sid for sid, _ in kills}
            else:
                ap.error('--verify requires --known-ids or --db')
                return
        else:
            with open(args.known_ids) as f:
                known = {int(l.strip()) for l in f if l.strip()}
        print(f"Loaded {len(known)} known dead spawn IDs.")
        verify_payloads(args.verify, known)
        return

    # -- correlation mode --
    if not args.events or not args.db:
        ap.error('--events and --db are required (or use --verify mode)')

    since_ms = int(__import__('time').time() * 1000) - args.since * 60_000 \
               if args.since > 0 else 0

    kills = load_kills(args.db, since_ms)
    print(f"Loaded {len(kills)} kills from spawn DB"
          + (f" (last {args.since} min)" if args.since else "") + ".")
    if not kills:
        print("No kills found. Kill some mobs and wait for corpse decay, then retry.")
        sys.exit(1)

    total, in_win, hit_kills = correlate(args.events, kills,
                                          args.decay_min, args.decay_max)

    if not total:
        print("No 4b/5b S>C zone-unknown packets found in events file.")
        print("Ensure --list-events was active during the capture session.")
        sys.exit(1)

    n = len(kills)
    print(f"\nDecay window: +{args.decay_min}s to +{args.decay_max}s after kill. {n} kills.")
    print(f"\n{'Opcode':8s}  {'Sz':>3s}  {'Total':>6s}  {'In-win':>6s}  "
          f"{'Kills-hit':>9s}  {'Ratio':>6s}  Verdict")
    print("-" * 65)

    # collect size per opcode
    sizes_seen = defaultdict(set)
    for ts, opcode, length in parse_events(args.events):
        sizes_seen[opcode].add(length)

    rows = []
    for opcode in total:
        hit = len(hit_kills.get(opcode, set()))
        ratio = hit / n
        verdict = ('STRONG'   if ratio >= 0.7 else
                   'moderate' if ratio >= 0.4 else
                   'weak'     if ratio >= 0.2 else
                   'noise')
        sz = ','.join(str(s) for s in sorted(sizes_seen.get(opcode, set())))
        rows.append((ratio, hit, opcode, sz, total[opcode], in_win[opcode], verdict))

    rows.sort(reverse=True)
    for ratio, hit, opcode, sz, tot, win, verdict in rows[:25]:
        print(f"{opcode:8s}  {sz:>3s}  {tot:>6d}  {win:>6d}  "
              f"{hit:>9d}  {ratio:>6.2f}  {verdict}")

    print("\nNext steps for STRONG candidates:")
    print("  1. Restart daemon with:  --dump-payload <opcode>:despawn.bin")
    print("  2. Kill mobs, wait for decay.")
    print("  3. python3 find-despawn-opcode.py --verify despawn.bin --db eq-spawns.db")


if __name__ == '__main__':
    main()
