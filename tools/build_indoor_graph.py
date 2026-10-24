#!/usr/bin/env python3
"""Build assets/maps/campus_indoor_graph.json from the three floor GeoJSON files.

Needs: python3, shapely, numpy, scipy   (pip install shapely numpy scipy)
Usage: python tools/build_indoor_graph.py assets/maps assets/maps/campus_indoor_graph.json

How it works (see README comments in the app):
  * Corridor (006), stairs (007) and elevator (008) polygons of each
    building floor are the walkable area. It is covered with a 1.5 m grid;
    neighbouring grid points are joined by edges.
  * Every other room gets one node at the same point the app uses as the
    room's center, joined to the nearest walkable point (the data has no
    doors, so the door position is approximate). Rooms that do not touch a
    corridor are joined through a neighbouring room.
  * Stairs/elevators on one floor are joined to the ones above them.
    Stairs are marked not accessible.
  * Vestibules/lobbies at the building edge become "entrance" nodes. The app
    joins those to the outdoor path graph when it loads.
"""
import json
import math
import re
import sys
from collections import defaultdict, Counter

import numpy as np
import shapely
from scipy.spatial import cKDTree
from shapely.geometry import Polygon, Point
from shapely.ops import unary_union, nearest_points

LAT0, LON0 = 29.578, -95.105
KX = 111320 * math.cos(math.radians(LAT0))
KY = 110574.0
CELL = 1.5                 # grid spacing in meters
DOOR_GAP = 1.0             # a room within this distance of walkable space has a door there
SUITE_GAP = 0.3            # rooms this close count as neighbours (suites)
JOIN_BIG_M = 10.0          # join a separate walkable piece (8+ points) within this distance
JOIN_SMALL_M = 6.0         # ... or a tiny piece within this distance
FALLBACK_GAP = 6.0         # last resort: join to nearest walkable point within this
STAIR_COST_M = 15.0        # extra "distance" for one flight of stairs
ELEVATOR_COST_M = 25.0     # extra "distance" for one elevator ride (waiting included)

K_CORRIDOR, K_ROOM, K_STAIRS, K_ELEVATOR, K_ENTRANCE = 1, 2, 3, 4, 5
FLOORS = (("01", "first"), ("02", "second"), ("03", "third"))


def proj(lon, lat):
    return ((lon - LON0) * KX, (lat - LAT0) * KY)


def unproj(x, y):
    return (LAT0 + y / KY, LON0 + x / KX)


def load_rooms(folder):
    rooms = []
    for floor, name in FLOORS:
        data = json.load(open(f"{folder}/campus_{name}_floor.geojson", encoding="utf-8"))
        for f in data["features"]:
            p = f["properties"]
            ring = f["geometry"]["coordinates"][0]
            lon_avg = sum(c[0] for c in ring) / len(ring)   # same as the app's center
            lat_avg = sum(c[1] for c in ring) / len(ring)
            if lon_avg < -95.12 or "PEARLAND" in (p.get("Building") or ""):
                continue          # other campus / a stray mis-located room
            poly = Polygon([proj(c[0], c[1]) for c in ring]).buffer(0)
            if poly.is_empty:
                continue
            rooms.append(dict(
                floor=int(floor), bld=p["Building"], num=(p.get("Room_Number") or "").strip(),
                name=(p.get("Room_Name") or "").strip(), use=(p.get("Use_") or "").strip(),
                poly=poly, center=(lat_avg, lon_avg), oid=p["OBJECTID_1"]))
    return rooms


class Builder:
    def __init__(self):
        self.nodes = []      # [lat, lon, floor, kind, bldg_index]
        self.xy = []         # projected (x, y)
        self.edges = {}      # (a, b) -> (length_m, accessible)
        self.buildings = []

    def bidx(self, name):
        if name not in self.buildings:
            self.buildings.append(name)
        return self.buildings.index(name)

    def add_node(self, x, y, floor, kind, bld, latlon=None):
        lat, lon = latlon if latlon else unproj(x, y)
        self.nodes.append([round(lat, 7), round(lon, 7), floor, kind, bld])
        self.xy.append((x, y))
        return len(self.nodes) - 1

    def add_edge(self, a, b, length=None, acc=1):
        a, b = int(a), int(b)
        if a == b:
            return
        if length is None:
            length = math.dist(self.xy[a], self.xy[b])
        key = (a, b) if a < b else (b, a)
        old = self.edges.get(key)
        if old is None or length < old[0]:
            self.edges[key] = (length, acc if old is None else min(acc, old[1]))


def build(folder, out_path):
    rooms = load_rooms(folder)
    B = Builder()
    groups = defaultdict(list)
    for r in rooms:
        groups[(r["bld"], r["floor"])].append(r)

    walk_nodes = {}        # (bld, floor) -> list of node ids (walkable)
    anchor = {}            # id(room dict) for stairs/elev -> node id
    room_node = {}         # id(room dict) -> node id
    stats = Counter()
    all_rooms = []         # (building, floor, polygon, node id)
    region_out = []        # walkable areas, used by the app to straighten routes
    footprint_out = []     # building outlines (shrunk 1 m), used to keep outdoor links off buildings

    for (bld, floor), rs in sorted(groups.items()):
        bi = B.bidx(bld)
        walk = [r for r in rs if r["use"][:3] in ("006", "007", "008")]
        if not walk:
            continue
        region = unary_union([r["poly"] for r in walk]).buffer(0.2).buffer(-0.2)
        shrunk = region.buffer(-0.15).simplify(0.1)
        for part in getattr(shrunk, "geoms", [shrunk]):
            if part.is_empty or part.geom_type != "Polygon":
                continue
            rings = [part.exterior] + list(part.interiors)
            region_out.append([bi, floor, [[[round(unproj(x, y)[0], 7), round(unproj(x, y)[1], 7)]
                                             for x, y in ring.coords] for ring in rings]])
        minx, miny, maxx, maxy = region.bounds
        gx = np.arange(minx + CELL / 2, maxx, CELL)
        gy = np.arange(miny + CELL / 2, maxy, CELL)
        X, Y = np.meshgrid(gx, gy)
        inside = shapely.contains_xy(region, X, Y)
        # kind per cell
        kind = np.where(inside, K_CORRIDOR, 0)
        for r in walk:
            k = {"007": K_STAIRS, "008": K_ELEVATOR}.get(r["use"][:3])
            if k:
                kind[shapely.contains_xy(r["poly"], X, Y) & inside] = k
        index = -np.ones(X.shape, dtype=int)
        ids = []
        for iy, ix in zip(*np.nonzero(inside)):
            n = B.add_node(X[iy, ix], Y[iy, ix], floor, int(kind[iy, ix]), bi)
            index[iy, ix] = n
            ids.append(n)
        # grid edges: E, N, NE, NW (midpoint must be inside, so no wall cutting)
        for dx, dy in ((1, 0), (0, 1), (1, 1), (-1, 1)):
            for iy, ix in zip(*np.nonzero(inside)):
                jy, jx = iy + dy, ix + dx
                if not (0 <= jy < X.shape[0] and 0 <= jx < X.shape[1]) or not inside[jy, jx]:
                    continue
                mx = (X[iy, ix] + X[jy, jx]) / 2
                my = (Y[iy, ix] + Y[jy, jx]) / 2
                if shapely.contains_xy(region, mx, my):
                    B.add_edge(index[iy, ix], index[jy, jx])
        # polygons too small for any grid point get a node of their own
        for r in walk:
            if not shapely.contains_xy(r["poly"], X.ravel(), Y.ravel()).any():
                rp = r["poly"].representative_point()
                n = B.add_node(rp.x, rp.y, floor, {"007": K_STAIRS, "008": K_ELEVATOR}.get(r["use"][:3], K_CORRIDOR), bi)
                ids.append(n)
                stats["sliver nodes"] += 1
        # join separate walkable pieces (e.g. a stairwell tower) to the nearest
        # other piece, closest pairs first
        if len(ids) > 1:
            xy_arr = np.array([B.xy[i] for i in ids])
            pos = {i: k for k, i in enumerate(ids)}
            parent = {i: i for i in ids}

            def find(a):
                while parent[a] != a:
                    parent[a] = parent[parent[a]]
                    a = parent[a]
                return a
            for (a, b) in [k for k in B.edges if k[0] in parent and k[1] in parent]:
                parent[find(a)] = find(b)
            while True:
                groups_ = defaultdict(list)
                for k, i in enumerate(ids):
                    groups_[find(i)].append(k)
                comp_lists = list(groups_.values())
                if len(comp_lists) == 1:
                    break
                best = None
                for ci, ks in enumerate(comp_lists):
                    other = np.array([k for cj, kk in enumerate(comp_lists) if cj != ci for k in kk])
                    d, j = cKDTree(xy_arr[other]).query(xy_arr[ks])
                    m = int(np.argmin(d))
                    limit = JOIN_BIG_M if len(ks) >= 8 else JOIN_SMALL_M
                    if d[m] <= limit and (best is None or d[m] < best[0]):
                        best = (d[m], ids[ks[m]], ids[other[j[m]]])
                if best is None:
                    break
                _, a, b = best
                parent[find(a)] = find(b)
                B.add_edge(a, b)
                stats["pieces joined"] += 1
        walk_nodes[(bld, floor)] = ids
        # remember an anchor node for stairs / elevators
        for r in walk:
            if r["use"][:3] in ("007", "008"):
                c = r["poly"].centroid
                cand_ids = [i for i in ids if shapely.contains_xy(r["poly"], B.xy[i][0], B.xy[i][1])]
                pool = cand_ids or ids
                anchor[id(r)] = min(pool, key=lambda i: math.dist(B.xy[i], (c.x, c.y)))

        # ---- rooms ----
        wtree = cKDTree([B.xy[i] for i in ids])
        others = [r for r in rs if r["use"][:3] not in ("006", "007", "008", "011")]
        for r in others:
            lat, lon = r["center"]
            x, y = proj(lon, lat)
            room_node[id(r)] = B.add_node(x, y, floor, K_ROOM, bi, latlon=(lat, lon))
            all_rooms.append((bld, floor, r["poly"], room_node[id(r)]))
        connected = set()
        gap = {}
        for r in others:
            gap[id(r)] = r["poly"].distance(region)
            if gap[id(r)] <= DOOR_GAP:
                p_corr = nearest_points(r["poly"], region)[1]
                d, j = wtree.query((p_corr.x, p_corr.y))
                n = room_node[id(r)]
                B.add_edge(n, ids[j], math.dist(B.xy[n], B.xy[ids[j]]))
                connected.add(id(r))
                stats["rooms via door"] += 1
        # suites: unconnected rooms join a touching connected room
        for _ in range(6):
            changed = False
            for r in others:
                if id(r) in connected:
                    continue
                best = None
                for q in others:
                    if id(q) in connected and q is not r and r["poly"].distance(q["poly"]) <= SUITE_GAP:
                        d = math.dist(B.xy[room_node[id(r)]], B.xy[room_node[id(q)]])
                        if best is None or d < best[0]:
                            best = (d, q)
                if best:
                    B.add_edge(room_node[id(r)], room_node[id(best[1])], best[0])
                    connected.add(id(r))
                    stats["rooms via suite"] += 1
                    changed = True
            if not changed:
                break
        for r in others:
            if id(r) not in connected and gap[id(r)] <= FALLBACK_GAP:
                p_corr = nearest_points(r["poly"], region)[1]
                d, j = wtree.query((p_corr.x, p_corr.y))
                n = room_node[id(r)]
                B.add_edge(n, ids[j], math.dist(B.xy[n], B.xy[ids[j]]))
                connected.add(id(r))
                stats["rooms via nearest (approx)"] += 1
        stats["rooms unconnected"] += sum(1 for r in others if id(r) not in connected)
        stats["rooms total"] += len(others)

    # ---- vertical links ----
    by_bld = defaultdict(lambda: defaultdict(list))
    for r in rooms:
        if r["use"][:3] in ("007", "008"):
            by_bld[r["bld"]][r["floor"]].append(r)
    for bld, fl in by_bld.items():
        for f in sorted(fl):
            for a in fl[f]:
                best = None
                for b in fl.get(f + 1, []):
                    if a["use"][:3] != b["use"][:3]:
                        continue
                    inter = a["poly"].intersection(b["poly"]).area
                    frac = inter / min(a["poly"].area, b["poly"].area)
                    if frac > 0.3 and (best is None or inter > best[0]):
                        best = (inter, b)
                if best and id(a) in anchor and id(best[1]) in anchor:
                    elev = a["use"][:3] == "008"
                    B.add_edge(anchor[id(a)], anchor[id(best[1])],
                               ELEVATOR_COST_M if elev else STAIR_COST_M, 1 if elev else 0)
                    stats["elevator links" if elev else "stair links"] += 1

    # ---- last pass: join cut-off pieces through touching rooms ----
    # (a stairwell tower or suite whose corridor is not in the data)
    from shapely.strtree import STRtree
    nn = len(B.nodes)
    par = list(range(nn))

    def fnd(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a
    for (a, b) in B.edges:
        par[fnd(a)] = fnd(b)
    by_bf = defaultdict(list)
    for item in all_rooms:
        by_bf[(item[0], item[1])].append(item)
    trees = {k: STRtree([it[2] for it in v]) for k, v in by_bf.items()}
    for _ in range(200):
        best = None
        for k, items in by_bf.items():
            for it in items:
                ra = fnd(it[3])
                for j in trees[k].query(it[2].buffer(SUITE_GAP), predicate="intersects"):
                    other = items[int(j)]
                    if fnd(other[3]) == ra:
                        continue
                    d = math.dist(B.xy[it[3]], B.xy[other[3]])
                    if d <= 30 and (best is None or d < best[0]):
                        best = (d, it[3], other[3])
        if best is None:
            break
        _, a, b = best
        B.add_edge(a, b)
        par[fnd(a)] = fnd(b)
        stats["pieces joined through rooms"] += 1

    # ---- entrances ----
    pat = re.compile(r"VEST|ENTR|LOBBY|FOYER|COMMONS", re.I)
    for bld in sorted({r["bld"] for r in rooms}):
        ground = [r for r in groups.get((bld, 1), [])]
        if not ground:
            continue
        footprint = unary_union([r["poly"] for r in ground]).buffer(0.3).buffer(-0.3)
        boundary = footprint.boundary
        bi = B.bidx(bld)
        inner = footprint.buffer(-1.0).simplify(0.2)
        for part in getattr(inner, "geoms", [inner]):
            if part.is_empty or part.geom_type != "Polygon":
                continue
            footprint_out.append([bi, [[[round(unproj(x, y)[0], 7), round(unproj(x, y)[1], 7)]
                                         for x, y in ring.coords] for ring in [part.exterior] + list(part.interiors)]])
        wl = walk_nodes.get((bld, 1), [])
        if not wl:
            continue
        wtree = cKDTree([B.xy[i] for i in wl])
        found = 0
        for r in ground:
            if r["use"][:3] != "006" or not pat.search(r["name"]):
                continue
            if r["poly"].distance(boundary) > 2.5:
                continue
            p = nearest_points(r["poly"], boundary)[1]
            d, j = wtree.query((p.x, p.y))
            if d > 6:
                continue
            n = B.add_node(p.x, p.y, 1, K_ENTRANCE, bi)
            B.add_edge(n, wl[j])
            found += 1
        if found == 0:      # no named vestibule: use the walkable point nearest the outside wall
            dist = [(Point(B.xy[i]).distance(boundary), i) for i in wl]
            d, i = min(dist)
            n = B.add_node(B.xy[i][0], B.xy[i][1], 1, K_ENTRANCE, bi)
            B.add_edge(n, i, 0.5)
            found = 1
            stats["buildings with fallback entrance"] += 1
        stats["entrances"] += found

    out = {
        "version": 1,
        "buildings": B.buildings,
        "nodes": B.nodes,
        "regions": region_out,
        "footprints": footprint_out,
        "edges": [[a, b, int(round(l * 10)), acc] for (a, b), (l, acc) in sorted(B.edges.items())],
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))
    print("nodes", len(B.nodes), "edges", len(B.edges))
    for k, v in sorted(stats.items()):
        print(f"  {k}: {v}")
    return B, rooms, room_node, walk_nodes


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2])
