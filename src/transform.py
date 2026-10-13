"""TRMNL Serverless transform for the Golden Globe Race 2026 tracker.

Runs on TRMNL's side after each poll. Fetches the YB Tracking race setup,
leaderboard and the binary position feed, decodes the positions, and returns
a compact set of merge variables for the Liquid template.
"""
import datetime
import struct
import time

import requests

RACE = "ggr2026"
BASE = "https://yb.tl"
NM = 1852.0  # metres per nautical mile
TIMEOUT = 4  # seconds; TRMNL kills the function after 5


def decode_positions(buf):
    """Port of YB's PositionParser.parse (AllPositions3 format).

    Returns {team_id: newest_moment} where a moment has lat, lon, at (unix), dtf (m).
    """
    flags = buf[0]
    has_alt, has_dtf, has_lap, has_pc = flags & 1, flags & 2, flags & 4, flags & 8
    ref = struct.unpack_from(">I", buf, 1)[0]
    p = 5
    latest = {}
    while p < len(buf):
        tid, n = struct.unpack_from(">HH", buf, p)
        p += 4
        prev = None
        for i in range(n):
            m = {}
            if buf[p] & 0x80:
                w = struct.unpack_from(">H", buf, p)[0]
                p += 2
                dlat, dlon = struct.unpack_from(">hh", buf, p)
                p += 4
                if has_alt:
                    p += 2
                if has_dtf:
                    d = struct.unpack_from(">h", buf, p)[0]
                    p += 2
                    m["dtf"] = prev["dtf"] + d
                    if has_lap:
                        p += 1
                if has_pc:
                    p += 2
                m["lat"] = prev["lat"] + dlat
                m["lon"] = prev["lon"] + dlon
                m["at"] = prev["at"] - (w & 0x7FFF)
            else:
                t, lat, lon = struct.unpack_from(">Iii", buf, p)
                p += 12
                if has_alt:
                    p += 2
                if has_dtf:
                    m["dtf"] = struct.unpack_from(">i", buf, p)[0]
                    p += 4
                    if has_lap:
                        p += 1
                if has_pc:
                    p += 4
                m["lat"], m["lon"], m["at"] = lat, lon, ref + t
            if i == 0:  # moments are newest-first
                latest[tid] = m
            prev = m
    for m in latest.values():
        m["lat"] /= 1e5
        m["lon"] /= 1e5
    return latest


def short_name(full, limit=16):
    """'Damien Guillou' -> 'D. Guillou'; long compound names collapse to initials + last name."""
    parts = full.split()
    if len(parts) < 2:
        return full
    short = parts[0][0] + ". " + " ".join(parts[1:])
    if len(short) > limit and len(parts) > 2:
        short = " ".join(p[0] + "." for p in parts[:-1]) + " " + parts[-1]
    return short


def course_segments(nodes, step=8):
    """Decimated course as [lon, lat] runs, split where it crosses the antimeridian."""
    pts = [[round(n["lon"], 1), round(n["lat"], 1)] for n in nodes]
    pts = pts[::step] + pts[-1:]
    segments, current = [], []
    for pt in pts:
        if current and abs(pt[0] - current[-1][0]) > 180:
            segments.append(current)
            current = []
        current.append(pt)
    if current:
        segments.append(current)
    return segments


def race_day(start, now):
    """Calendar day of the race in UTC, the start day being day 1."""
    if not start:
        return None
    d0 = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).date()
    d1 = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date()
    return (d1 - d0).days + 1


def run(input):
    s = requests.Session()
    setup = s.get(f"{BASE}/JSON/{RACE}/RaceSetup", timeout=TIMEOUT).json()
    board = s.get(f"{BASE}/JSON/{RACE}/leaderboard", timeout=TIMEOUT).json()
    positions = decode_positions(s.get(f"{BASE}/BIN/{RACE}/AllPositions3", timeout=TIMEOUT).content)

    tags = {t["id"]: t for t in setup.get("tags", [])}
    main_tag = next((t["id"] for t in tags.values() if t.get("sort") == 1), None)
    ranks = {}
    tag_of = {}
    for tag in board.get("tags", []):
        for row in tag["teams"]:
            tag_of.setdefault(row["id"], tag["id"])
            ranks.setdefault(row["id"], row)

    race_start = None
    boats = []
    for team in setup["teams"]:
        tid = team["id"]
        tag_id = team.get("tags", [None])[0]
        tag_name = tags.get(tag_id, {}).get("name", "")
        if tag_name == "Previous Competitors":
            continue  # historical ghost tracks, not racing this year
        row = ranks.get(tid, {})
        pos = positions.get(tid)
        race_start = race_start or team.get("start")
        dtf_m = row.get("dtf") if row.get("dtf") is not None else (pos or {}).get("dtf")
        boats.append({
            "skipper": team["name"],
            "short": short_name(team["name"]),
            "boat": team.get("owner") or "",
            "flag": team.get("flag") or "",
            "status": team.get("status") or row.get("status") or "",
            "chichester": tag_name == "Chichester Class",
            "rank": row.get("rankR"),
            "dtf_nm": round(dtf_m / NM) if dtf_m is not None else None,
            "d24_nm": max(0, round(row["d24"] / NM)) if row.get("d24") is not None else None,
            "lat": pos["lat"] if pos else None,
            "lon": pos["lon"] if pos else None,
            "at": pos["at"] if pos else None,
        })

    # Overall order: racing boats by rank, then Chichester, then retired.
    def order(b):
        racing = b["status"] == "RACING" and not b["chichester"]
        return (0 if racing else 1 if b["chichester"] else 2, b["rank"] or 999, b["dtf_nm"] or 10**9)

    boats.sort(key=order)
    for i, b in enumerate(boats, 1):
        b["pos"] = i

    now = int(time.time())
    newest = max((b["at"] for b in boats if b["at"]), default=now)
    return {
        "course": course_segments(setup.get("course", {}).get("nodes", [])),
        "race": {
            "title": setup.get("title", "Golden Globe Race"),
            "start": race_start,
            "day": race_day(race_start, now),
            "updated": newest,
            "racing": sum(1 for b in boats if b["status"] == "RACING"),
            "total": len(boats),
        },
        "boats": boats,
    }


if __name__ == "__main__":  # local check: python3 src/transform.py
    import json
    out = run({})
    print(json.dumps(out, indent=1))
    print("bytes:", len(json.dumps(out)))
