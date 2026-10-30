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
import os
import re
import sys
from collections import defaultdict, Counter

import numpy as np
import shapely
from scipy.spatial import cKDTree
from shapely.geometry import Polygon, Point, LineString
from shapely.ops import unary_union, nearest_points

# the GIS files were moved 1.35 m east / 2.65 m north to line up with OpenStreetMap (tools/align_layers.py);
# the origin moves with them so the door hints in door_hints.json (meters) keep their meaning
LAT0, LON0 = 29.578 + 2.65 / 110574.0, -95.105 + 1.35 / (111320 * math.cos(math.radians(29.578)))
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


def load_door_hints():
    """tools/door_hints.json: hand-placed doors.
    {building: {room number: [x, y]  or  {"door": [x, y], "via": [x, y]}}}
    "via" is a shared point (e.g. the middle of an alcove): the door joins it, and it
    joins the hallway line at right angles, so rooms sharing a via form a T."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "door_hints.json")
    if not os.path.exists(path):
        return {}
    data = json.load(open(path, encoding="utf-8"))
    out = {}
    for b, rs in data.items():
        if b.startswith("_") or b in ("vertical_links", "rules_buildings", "open_rooms"):
            continue
        for n, v in rs.items():
            out[(b, n)] = v if isinstance(v, dict) else {"door": v}
    return out


def load_rule_buildings():
    """Buildings that get the door-at-alcove and right-angle rules (tools/door_hints.json "rules_buildings")."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "door_hints.json")
    if not os.path.exists(path):
        return set()
    return set(json.load(open(path, encoding="utf-8")).get("rules_buildings", []))


def load_open_rooms():
    """Rooms treated as open walkable space (a lab or atrium): {building: {room numbers}}."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "door_hints.json")
    if not os.path.exists(path):
        return {}
    return {b: set(v) for b, v in json.load(open(path, encoding="utf-8")).get("open_rooms", {}).items()}


def load_vertical_links():
    """tools/door_hints.json "vertical_links": stairs or elevators missing from the data.
    [{"building": ..., "type": "stairs"|"elevator", "bottom": {"floor": 1, "xy": [x, y]},
      "top": {"floor": 2, "xy": [x, y]}}]"""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "door_hints.json")
    if not os.path.exists(path):
        return []
    return json.load(open(path, encoding="utf-8")).get("vertical_links", [])


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

    def move_node(self, n, x, y):
        """Put node n at (x, y). The first move remembers the original spot as
        the node's anchor (lat, lon) so the app can still find it by the room's center."""
        node = self.nodes[n]
        if len(node) == 5:
            node.extend([node[0], node[1]])
        lat, lon = unproj(x, y)
        node[0], node[1] = round(lat, 7), round(lon, 7)
        self.xy[n] = (x, y)

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


SKEL_STEP = 0.5            # boundary sampling for the centerline, meters
SKEL_MIN_ANGLE = 45.0      # ignore Voronoi ridges that only hug a corner
SKEL_SPUR_M = 6.0          # remove side branches shorter than this
SKEL_SIMPLIFY = 0.9         # straighten hallway lines: wobble up to this many meters is removed
SKEL_MAX_EDGE = 1.5        # split long centerline edges so rooms/doors can attach


def _densify(ring, step):
    n = max(4, int(ring.length / step))
    return [ring.interpolate(i * ring.length / n) for i in range(n)]


def skeleton_edges(region):
    """Centerline of a walkable polygon as a list of ((x,y),(x,y)) segments."""
    from scipy.spatial import Voronoi
    pts = []
    for part in getattr(region, "geoms", [region]):
        if part.geom_type != "Polygon" or part.is_empty:
            continue
        for ring in [part.exterior] + list(part.interiors):
            pts.extend((p.x, p.y) for p in _densify(ring, SKEL_STEP))
    if len(pts) < 4:
        return []
    pts = np.array(pts)
    vor = Voronoi(pts)
    inner = region.buffer(-0.05)
    segs = []
    cos_min = math.cos(math.radians(SKEL_MIN_ANGLE))
    for (p, q), (v1, v2) in zip(vor.ridge_points, vor.ridge_vertices):
        if v1 < 0 or v2 < 0:
            continue
        a, b = vor.vertices[v1], vor.vertices[v2]
        if not (shapely.contains_xy(inner, a[0], a[1]) and shapely.contains_xy(inner, b[0], b[1])):
            continue
        mid = (a + b) / 2
        u, w = pts[p] - mid, pts[q] - mid
        nu, nw = np.linalg.norm(u), np.linalg.norm(w)
        if nu < 1e-9 or nw < 1e-9:
            continue
        if float(np.dot(u, w) / (nu * nw)) > cos_min:      # angle too small: corner hugging
            continue
        segs.append((tuple(a), tuple(b)))
    return segs


AXIS_TOL_DEG = 15.0        # a hallway line within this angle of the building's axes is left alone


def squared(poly, region, theta, tol=AXIS_TOL_DEG):
    """Replace diagonal stretches by two legs along the building's own axes
    (a hallway runs parallel to the walls, it does not cut corners)."""
    c, s_ = math.cos(theta), math.sin(theta)
    fwd = lambda p: (p[0] * c + p[1] * s_, -p[0] * s_ + p[1] * c)
    back = lambda u: (u[0] * c - u[1] * s_, u[0] * s_ + u[1] * c)
    ok_zone = region.buffer(0.3)
    out = [poly[0]]
    for a, b in zip(poly, poly[1:]):
        ua, ub = fwd(a), fwd(b)
        dx, dy = ub[0] - ua[0], ub[1] - ua[1]
        ang = math.degrees(math.atan2(abs(dy), abs(dx)))
        if ang <= tol or ang >= 90 - tol:
            out.append(b)
            continue
        jog = min(abs(dy), abs(dx)) if ang < 45 else min(abs(dy), abs(dx))
        if jog < 0.12:
            out.append(b)
            continue
        best = None
        for corner_u in ((ub[0], ua[1]), (ua[0], ub[1])):
            corner = back(corner_u)
            if ok_zone.contains(LineString([a, corner])) and ok_zone.contains(LineString([corner, b])):
                best = corner
                break
        if best is not None:
            out.append((round(best[0], 2), round(best[1], 2)))
        out.append(b)
    return out


def clean_skeleton(segs, region=None, theta=None, tol=AXIS_TOL_DEG):
    """Merge chains, simplify, prune short spurs. Returns (points, edges)."""
    q = lambda p: (round(p[0], 2), round(p[1], 2))
    adj = defaultdict(set)
    for a, b in segs:
        a, b = q(a), q(b)
        if a != b:
            adj[a].add(b)
            adj[b].add(a)

    def chains():
        """Split into chains between nodes of degree != 2."""
        seen = set()
        out = []
        for n in list(adj):
            if len(adj[n]) == 2:
                continue
            for m in adj[n]:
                if (n, m) in seen:
                    continue
                chain = [n, m]
                seen.add((n, m))
                while len(adj[chain[-1]]) == 2:
                    nxt = [x for x in adj[chain[-1]] if x != chain[-2]][0]
                    seen.add((chain[-1], nxt))
                    chain.append(nxt)
                seen.add((chain[-1], chain[-2]))
                out.append(chain)
        # pure cycles
        used = {n for c in out for n in c}
        for n in list(adj):
            if n in used or len(adj[n]) != 2:
                continue
            chain = [n]
            prev, cur = None, n
            while True:
                nxt = [x for x in adj[cur] if x != prev]
                nxt = nxt[0] if nxt else None
                if nxt is None or nxt == n:
                    chain.append(n)
                    break
                chain.append(nxt)
                prev, cur = cur, nxt
                if len(chain) > 5000:
                    break
            used.update(chain)
            out.append(chain)
        return out

    for _ in range(3):      # prune short leaf branches
        removed = False
        for c in chains():
            length = sum(math.dist(c[i], c[i + 1]) for i in range(len(c) - 1))
            leaf_a, leaf_b = len(adj[c[0]]) == 1, len(adj[c[-1]]) == 1
            if (leaf_a != leaf_b) and length < SKEL_SPUR_M:
                interior = c[:-1] if leaf_a else c[1:]
                for n in interior:
                    for m in list(adj[n]):
                        adj[m].discard(n)
                    adj.pop(n, None)
                removed = True
        for n in [n for n in adj if not adj[n]]:
            adj.pop(n)
        if not removed:
            break

    points, edges = {}, []

    def pid(p):
        if p not in points:
            points[p] = len(points)
        return points[p]
    for c in chains():
        simp = list(LineString(c).simplify(SKEL_SIMPLIFY).coords) if len(c) > 2 else c
        simp = [q(p) for p in simp]
        if region is not None and theta is not None:
            simp = squared(simp, region, theta, tol)
        for a, b in zip(simp, simp[1:]):
            d = math.dist(a, b)
            k = max(1, int(math.ceil(d / SKEL_MAX_EDGE)))
            prev = a
            for i in range(1, k + 1):
                cur = b if i == k else (a[0] + (b[0] - a[0]) * i / k, a[1] + (b[1] - a[1]) * i / k)
                edges.append((pid(prev), pid(cur)))
                prev = cur
    return list(points), edges


def _clean_ring(coords):
    pts = list(coords)[:-1]
    changed = True
    while changed and len(pts) > 4:
        changed = False
        for i in range(len(pts)):
            a, b, c = pts[i - 1], pts[i], pts[(i + 1) % len(pts)]
            v1 = (b[0] - a[0], b[1] - a[1])
            v2 = (c[0] - b[0], c[1] - b[1])
            if math.hypot(*v1) < 0.15 or abs(v1[0] * v2[1] - v1[1] * v2[0]) < 0.05 * math.hypot(*v1) * math.hypot(*v2):
                del pts[i]
                changed = True
                break
    return pts


def find_nubs(corr_union):
    """Door alcoves ("nubs"): short U-shaped bumps in the hallway outline.
    Returns dicts with the outline points p0..p3 (side A = p0-p1, end wall B = p1-p2, side C = p2-p3)."""
    from shapely.geometry.polygon import orient
    nubs = []
    for part in getattr(corr_union, "geoms", [corr_union]):
        if part.geom_type != "Polygon" or part.is_empty:
            continue
        part = orient(part, 1.0)
        for ring in [part.exterior] + list(part.interiors):
            P = _clean_ring(ring.coords)
            n = len(P)
            for i in range(n):
                p0, p1, p2, p3 = P[i], P[(i + 1) % n], P[(i + 2) % n], P[(i + 3) % n]
                A = (p1[0] - p0[0], p1[1] - p0[1])
                B_ = (p2[0] - p1[0], p2[1] - p1[1])
                C = (p3[0] - p2[0], p3[1] - p2[1])
                la, lb, lc = math.hypot(*A), math.hypot(*B_), math.hypot(*C)
                if not (0.3 <= la <= 3.5 and 0.3 <= lc <= 3.5 and 0.8 <= lb <= 4.5):
                    continue
                if not (A[0] * B_[1] - A[1] * B_[0] > 0 and B_[0] * C[1] - B_[1] * C[0] > 0):
                    continue
                if (A[0] * C[0] + A[1] * C[1]) / (la * lc) < -0.94 and abs(A[0] * B_[0] + A[1] * B_[1]) / (la * lb) < 0.21:
                    d = (A[0] / la, A[1] / la)             # points from the hallway into the alcove
                    t = min(la, lc) / 2
                    m = ((p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2)
                    nubs.append(dict(
                        walls={"A": LineString([p0, p1]), "B": LineString([p1, p2]), "C": LineString([p2, p3])},
                        door={"A": (p1[0] - d[0] * t, p1[1] - d[1] * t), "B": m,
                              "C": (p2[0] - d[0] * t, p2[1] - d[1] * t)},
                        via=(m[0] - d[0] * t, m[1] - d[1] * t)))
    return nubs


def axis_foot_of(B, ids, v, floor, bi, region, theta):
    """Straight out from node v along a building axis (into open space, not along a wall) until it
    meets a hallway line; the shortest clear way. Returns that node, or None if there is none."""
    vx, vy = B.xy[v]
    inner = region.buffer(-0.25)
    idset = set(ids)
    segs = [(a, b) for (a, b) in B.edges if a in idset and b in idset]
    best = None
    for k in range(4):
        ang = theta + k * math.pi / 2
        dx, dy = math.cos(ang), math.sin(ang)
        if not inner.contains(Point(vx + dx * 0.8, vy + dy * 0.8)):
            continue
        for a, b in segs:
            ax, ay = B.xy[a]
            bx, by = B.xy[b]
            ex, ey = bx - ax, by - ay
            den = dx * ey - dy * ex
            if abs(den) < 1e-9:
                continue
            wx, wy = ax - vx, ay - vy
            t = (wx * ey - wy * ex) / den          # distance along the ray
            u = (wx * dy - wy * dx) / den          # position along the segment
            if t > 0.3 and -1e-6 <= u <= 1 + 1e-6 and (best is None or t < best[0]):
                hit = (vx + dx * t, vy + dy * t)
                if region.buffer(0.3).contains(LineString([(vx, vy), hit])):
                    best = (t, a, b, u, math.hypot(ex, ey), hit)
    if best is None:
        return None
    _, a, b, u, length, (px, py) = best
    if u * length < 0.4:
        return a
    if (1 - u) * length < 0.4:
        return b
    acc = B.edges[(a, b) if a < b else (b, a)][1]
    del B.edges[(a, b) if a < b else (b, a)]
    p = B.add_node(px, py, floor, K_CORRIDOR, bi)
    ids.append(p)
    B.add_edge(a, p, acc=acc)
    B.add_edge(p, b, acc=acc)
    return p


def skeleton_foot_of(B, ids, v, floor, bi):
    """Node on the hallway line (nodes `ids`) closest to node v; splits a line segment if needed."""
    vx, vy = B.xy[v]
    idset = set(ids)
    best = None
    for (a, b), (_, acc) in B.edges.items():
        if a in idset and b in idset:
            ax, ay = B.xy[a]
            bx, by = B.xy[b]
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            if l2 == 0:
                continue
            t = max(0.0, min(1.0, ((vx - ax) * dx + (vy - ay) * dy) / l2))
            dd = math.hypot(vx - (ax + t * dx), vy - (ay + t * dy))
            if best is None or dd < best[0]:
                best = (dd, a, b, t, math.sqrt(l2), acc, ax + t * dx, ay + t * dy)
    _, a, b, t, length, acc, px, py = best
    if t * length < 0.4:
        return a
    if (1 - t) * length < 0.4:
        return b
    del B.edges[(a, b) if a < b else (b, a)]
    p = B.add_node(px, py, floor, K_CORRIDOR, bi)
    ids.append(p)
    B.add_edge(a, p, acc=acc)
    B.add_edge(p, b, acc=acc)
    return p


def build(folder, out_path):
    rooms = load_rooms(folder)
    hints = load_door_hints()
    rule_blds = load_rule_buildings()
    open_rooms = load_open_rooms()
    B = Builder()
    groups = defaultdict(list)
    for r in rooms:
        groups[(r["bld"], r["floor"])].append(r)

    zones = {}             # (bld, floor) -> (hallway area, [room polygons]) for the right-angle pass
    walk_nodes = {}        # (bld, floor) -> hallway node ids
    anchor = {}            # id(room dict) for stairs/elev -> node id
    room_node = {}         # id(room dict) -> node id
    stats = Counter()
    all_rooms = []         # (building, floor, polygon, node id)
    footprint_out = []     # building outlines (shrunk 1 m), used to keep outdoor links off buildings

    def door_link(a, b, pa, pb, bi, floor):
        """Join two spaces through a door node placed in the wall between them."""
        inter = pa.buffer(0.3).intersection(pb.buffer(0.3))
        if inter.is_empty:
            B.add_edge(a, b)
            return
        c = inter.centroid
        d = B.add_node(c.x, c.y, floor, K_CORRIDOR, bi)
        B.add_edge(a, d)
        B.add_edge(d, b)

    theta_of = {}
    for bld in {r["bld"] for r in rooms}:
        foot = unary_union([r["poly"] for r in rooms if r["bld"] == bld]).minimum_rotated_rectangle
        xs, ys = foot.exterior.coords.xy
        e = max(range(4), key=lambda k: math.dist((xs[k], ys[k]), (xs[k + 1], ys[k + 1])))
        theta_of[bld] = math.atan2(ys[e + 1] - ys[e], xs[e + 1] - xs[e])

    for (bld, floor), rs in sorted(groups.items()):
        bi = B.bidx(bld)
        corr = [r for r in rs if r["use"][:3] == "006"]
        special = [r for r in rs if r["use"][:3] in ("007", "008")]
        if not corr and not special:
            continue
        open_rs = [r for r in rs if r["num"] in open_rooms.get(bld, ())]
        region = (unary_union([r["poly"] for r in corr + open_rs]).buffer(0.2).buffer(-0.2)
                  if (corr or open_rs) else Polygon())
        hall_part = (unary_union([r["poly"] for r in corr]).buffer(0.2).buffer(-0.2) if corr else Polygon())

        # ---- hallway centerlines ----
        ids = []
        if not hall_part.is_empty:
            pts, edges = clean_skeleton(skeleton_edges(hall_part), region, theta_of[bld], 1.0 if bld in rule_blds else AXIS_TOL_DEG)
            local = [B.add_node(x, y, floor, K_CORRIDOR, bi) for x, y in pts]
            ids.extend(local)
            for a, b in edges:
                B.add_edge(local[a], local[b])
            # corridor pieces the centerline missed (tiny or odd shapes)
            if ids:
                tree = cKDTree([B.xy[i] for i in ids])
            for r in corr:
                rp = r["poly"].representative_point()
                if not ids or tree.query((rp.x, rp.y))[0] > 3.0:
                    ids.append(B.add_node(rp.x, rp.y, floor, K_CORRIDOR, bi))
                    stats["sliver nodes"] += 1
                    tree = cKDTree([B.xy[i] for i in ids])
        # open rooms (a big lab): one straight line along each building axis, crossing in the middle
        lab_center = {}
        for r in open_rs:
            th = theta_of[bld]
            ax_u, ax_v = (math.cos(th), math.sin(th)), (-math.sin(th), math.cos(th))
            inner = r["poly"].buffer(-0.6)
            c = r["poly"].centroid
            if not inner.contains(c):
                c = inner.representative_point()
            spine = []
            for dirv in (ax_u, ax_v):
                line = LineString([(c.x - 300 * dirv[0], c.y - 300 * dirv[1]), (c.x + 300 * dirv[0], c.y + 300 * dirv[1])])
                part = inner.intersection(line)
                pieces = [g for g in getattr(part, "geoms", [part]) if g.geom_type == "LineString" and not g.is_empty]
                piece = min(pieces, key=lambda g: g.distance(c))
                spine.append(list(piece.coords))
            center = B.add_node(c.x, c.y, floor, K_CORRIDOR, bi)
            ids.append(center)
            lab_center[id(r)] = center
            lab_nodes = [center]
            for coords in spine:
                for end in (coords[0], coords[-1]):
                    if math.dist(end, (c.x, c.y)) < 0.5:
                        continue
                    k = B.add_node(end[0], end[1], floor, K_CORRIDOR, bi)
                    ids.append(k)
                    lab_nodes.append(k)
                    B.add_edge(center, k)
            # join the lab to the hallways it opens onto
            others_ids = [i for i in ids if i not in lab_nodes]
            if others_ids:
                tree_o = cKDTree([B.xy[i] for i in others_ids])
                best = min(((tree_o.query(B.xy[k])[0], k, others_ids[int(tree_o.query(B.xy[k])[1])]) for k in lab_nodes))
                if best[0] <= 25:
                    B.add_edge(best[1], best[2])
            stats["open rooms"] += 1
        # join separate hallway pieces, closest pairs first
        if len(ids) > 1:
            xy_arr = np.array([B.xy[i] for i in ids])
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
        zones[(bld, floor)] = (region.buffer(0.3), [r["poly"].buffer(0.3) for r in rs])
        skel_tree = cKDTree([B.xy[i] for i in ids]) if ids else None
        rules_on = bld in rule_blds
        nubs = find_nubs(unary_union([r["poly"] for r in corr + open_rs])) if (rules_on and (corr or open_rs)) else []
        nub_assign = {}            # id(room) -> (nub index, wall letter)
        nub_via = {}               # nub index -> via node

        # ---- rooms, stairs, elevators ----
        others = [r for r in rs if r["use"][:3] not in ("006", "007", "008", "011")]
        for r in others:
            lat, lon = r["center"]
            x, y = proj(lon, lat)
            room_node[id(r)] = B.add_node(x, y, floor, K_ROOM, bi, latlon=(lat, lon))
        for r in special:
            rp = r["poly"].representative_point()
            k = K_STAIRS if r["use"][:3] == "007" else K_ELEVATOR
            room_node[id(r)] = B.add_node(rp.x, rp.y, floor, k, bi)
            anchor[id(r)] = room_node[id(r)]
        spaces = others + special
        for r in spaces:
            all_rooms.append((bld, floor, r["poly"], room_node[id(r)]))
        # Which room uses which alcove wall. An alcove between two different rooms gets a door
        # on each side (a T); an alcove that serves one room gets one door at the middle of its end wall.
        cand = defaultdict(list)           # id(room) -> [(score, nub index, wall letter)]
        usable = [r for r in spaces if r["use"][:3] != "009" and (bld, r["num"]) not in hints
                  and r["num"] not in open_rooms.get(bld, ())]
        for ni, nub in enumerate(nubs):
            def overlap(letter, r):
                return nub["walls"][letter].intersection(r["poly"].buffer(0.3)).length
            on_end = sorted(((overlap("B", r), r) for r in usable if overlap("B", r) >= 0.6),
                            key=lambda t: -t[0])
            sides = None
            if len(on_end) >= 2:               # a wall between two rooms meets the end wall: door on each side
                (l1, r1), (l2, r2) = on_end[0], on_end[1]
                s1 = "A" if overlap("A", r1) >= overlap("C", r1) else "C"
                s2 = "A" if overlap("A", r2) >= overlap("C", r2) else "C"
                if s1 != s2 and overlap(s1, r1) >= 0.8 and overlap(s2, r2) >= 0.8:
                    sides = ((r1, s1, overlap(s1, r1)), (r2, s2, overlap(s2, r2)))
            if sides:
                for r, letter, L in sides:
                    cand[id(r)].append((round(L, 1), ni, letter))
            else:                              # one room: single door in the middle of the end wall
                if on_end:
                    L, r = on_end[0]
                else:
                    scored = [(sum(overlap(k, r) for k in "ABC"), r) for r in usable]
                    scored = [t for t in scored if t[0] >= 0.8]
                    if not scored:
                        continue
                    L, r = max(scored, key=lambda t: t[0])
                cand[id(r)].append((round(L, 1), ni, "B"))
        for r in spaces:
            if cand.get(id(r)):
                _, ni, letter = max(cand[id(r)])
                nub_assign[id(r)] = (ni, letter)
        side_nubs = {ni for ni, letter in nub_assign.values() if letter in "AC"}

        via_nodes = {}

        def skeleton_foot(v):
            if rules_on:
                hit = axis_foot_of(B, ids, v, floor, bi, region, theta_of[bld])
                if hit is not None:
                    return hit
            return skeleton_foot_of(B, ids, v, floor, bi)

        def hall_door(r):
            """Door in the wall facing the hallway, joined to the centerline."""
            n = room_node[id(r)]
            if id(r) in lab_center:                 # an open room: its node sits at the crossing of its two lines
                c = lab_center[id(r)]
                B.move_node(n, B.xy[c][0], B.xy[c][1])
                B.add_edge(n, c, 0.1)
                return
            cx, cy = B.xy[n]
            s0 = B.xy[ids[skel_tree.query((cx, cy))[1]]]
            spec = hints.get((bld, r["num"]))
            hint = spec.get("door") if spec else None
            if spec and spec.get("doors"):
                hint = spec["doors"][0]
            wall = r["poly"].exterior.intersection(region.buffer(DOOR_GAP + 0.1))
            if hint is not None:
                p_room = nearest_points(r["poly"].exterior, Point(hint))[0]
                stats["doors from hints"] += 1
            elif id(r) in nub_assign:
                ni, letter = nub_assign[id(r)]
                p_room = Point(nubs[ni]["door"][letter])
                stats["doors at alcoves"] += 1
            elif wall.is_empty:
                p_room = nearest_points(r["poly"], region)[0]
            else:
                p_room = nearest_points(wall, Point(s0))[0]
            j = skel_tree.query((p_room.x, p_room.y))[1]
            B.move_node(n, p_room.x, p_room.y)      # the room's node sits on its door
            if spec and spec.get("via"):
                vx, vy = spec["via"]
                key = (round(vx, 2), round(vy, 2))
                if key not in via_nodes:
                    via_nodes[key] = B.add_node(vx, vy, floor, K_CORRIDOR, bi)
                    B.add_edge(via_nodes[key], skeleton_foot(via_nodes[key]))
                B.add_edge(n, via_nodes[key])
                stats["T junctions"] += 1
            elif id(r) in nub_assign:
                ni, letter = nub_assign[id(r)]
                if ni in side_nubs:                 # T: doors on the sides, stem down the middle
                    if ni not in nub_via:
                        nub_via[ni] = B.add_node(nubs[ni]["via"][0], nubs[ni]["via"][1], floor, K_CORRIDOR, bi)
                        B.add_edge(nub_via[ni], skeleton_foot(nub_via[ni]))
                    B.add_edge(n, nub_via[ni])
                else:                               # shallow recess: straight in along its axis
                    B.add_edge(n, skeleton_foot(n))
            elif rules_on:
                B.add_edge(n, skeleton_foot(n))     # straight across the hallway, not to the nearest node
            else:
                B.add_edge(n, ids[j])
            if spec and spec.get("doors") and len(spec["doors"]) > 1:
                for extra in spec["doors"][1:]:     # a room with more than one entrance
                    q = nearest_points(r["poly"].exterior, Point(extra))[0]
                    nn = B.nodes[n]
                    k = B.add_node(q.x, q.y, floor, K_ROOM, bi, latlon=(nn[5], nn[6]))
                    B.move_node(k, q.x, q.y)           # same room, a second door: its own node, no line through the room
                    B.add_edge(k, skeleton_foot(k))
                    stats["extra doors"] += 1

        connected = set()
        gap = {}
        for r in spaces:
            gap[id(r)] = r["poly"].distance(region) if not region.is_empty else 1e9
            if skel_tree is not None and (gap[id(r)] <= DOOR_GAP or hints.get((bld, r["num"]))):
                hall_door(r)
                connected.add(id(r))
                stats["rooms via door"] += 1
        # suites: unconnected rooms join a touching connected room through a shared wall
        for _ in range(6):
            changed = False
            for r in spaces:
                if id(r) in connected:
                    continue
                best = None
                for q in spaces:
                    if id(q) in connected and q is not r and r["poly"].distance(q["poly"]) <= SUITE_GAP:
                        d = math.dist(B.xy[room_node[id(r)]], B.xy[room_node[id(q)]])
                        if best is None or d < best[0]:
                            best = (d, q)
                if best:
                    q = best[1]
                    inter = r["poly"].buffer(0.3).intersection(q["poly"].buffer(0.3))
                    if not inter.is_empty:
                        c = inter.centroid           # door in the wall the two rooms share
                        B.move_node(room_node[id(r)], c.x, c.y)
                    B.add_edge(room_node[id(r)], room_node[id(q)])
                    connected.add(id(r))
                    stats["rooms via suite"] += 1
                    changed = True
            if not changed:
                break
        for r in spaces:
            if id(r) not in connected and skel_tree is not None and gap[id(r)] <= FALLBACK_GAP:
                hall_door(r)
                connected.add(id(r))
                stats["rooms via nearest (approx)"] += 1
        stats["rooms unconnected"] += sum(1 for r in spaces if id(r) not in connected)
        stats["rooms total"] += len(spaces)

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

    # ---- stairs / elevators added by hand (tools/door_hints.json) ----
    for link in load_vertical_links():
        bld = link["building"]
        bi = B.bidx(bld)
        elev = link.get("type", "stairs") == "elevator"
        ends = []
        for end in (link["bottom"], link["top"]):
            fl = end["floor"]
            hall = walk_nodes.get((bld, fl))
            if not hall:
                sys.exit(f"vertical link: no hallway on floor {fl} of {bld}")
            n = B.add_node(end["xy"][0], end["xy"][1], fl, K_ELEVATOR if elev else K_STAIRS, bi)
            B.add_edge(n, skeleton_foot_of(B, hall, n, fl, bi))
            ends.append(n)
        B.add_edge(ends[0], ends[1], ELEVATOR_COST_M if elev else STAIR_COST_M, 1 if elev else 0)
        stats["manual elevator links" if elev else "manual stair links"] += 1

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
                        best = (d, it[3], other[3], it[2], other[2], it[0], it[1])
        if best is None:
            break
        _, a, b, pa, pb, bname, fl = best
        door_link(a, b, pa, pb, B.bidx(bname), fl)
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

    # ---- right angles only (buildings listed in "rules_buildings") ----
    def leg_ok(zone, p, q):
        seg = LineString([p, q])
        if zone[0].contains(seg):
            return True
        if any(poly.contains(seg) for poly in zone[1]):
            return True
        # a link between two touching rooms (a suite door): the legs may use both rooms
        near = [poly for poly in zone[1] if poly.distance(Point(p)) < 0.05 or poly.distance(Point(q)) < 0.05]
        return len(near) >= 2 and unary_union(near + [zone[0]]).buffer(0.05).contains(seg)

    squared_n = left_n = 0
    for (a, b), (length, acc) in sorted(B.edges.items()):
        na, nb = B.nodes[a], B.nodes[b]
        if na[2] != nb[2] or na[4] != nb[4]:
            continue
        bld = B.buildings[na[4]]
        if bld not in rule_blds or (bld, na[2]) not in zones:
            continue
        th = theta_of[bld]
        c_, s_ = math.cos(th), math.sin(th)
        pa, pb = B.xy[a], B.xy[b]
        ua = (pa[0] * c_ + pa[1] * s_, -pa[0] * s_ + pa[1] * c_)
        ub = (pb[0] * c_ + pb[1] * s_, -pb[0] * s_ + pb[1] * c_)
        dx, dy = ub[0] - ua[0], ub[1] - ua[1]
        if math.hypot(dx, dy) < 0.3:
            continue
        ang = math.degrees(math.atan2(abs(dy), abs(dx)))
        if ang <= 5 or ang >= 85:
            continue
        done = False
        for cu in ((ub[0], ua[1]), (ua[0], ub[1])):
            corner = (cu[0] * c_ - cu[1] * s_, cu[0] * s_ + cu[1] * c_)
            if leg_ok(zones[(bld, na[2])], pa, corner) and leg_ok(zones[(bld, na[2])], corner, pb):
                k = B.add_node(corner[0], corner[1], na[2], K_CORRIDOR, na[4])
                del B.edges[(a, b)]
                B.add_edge(a, k, acc=acc)
                B.add_edge(k, b, acc=acc)
                squared_n += 1
                done = True
                break
        if not done:
            left_n += 1
    stats["diagonal edges squared"] += squared_n
    stats["diagonal edges left (no clear right-angle path)"] += left_n

    out = {
        "version": 1,
        "buildings": B.buildings,
        "nodes": B.nodes,
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
