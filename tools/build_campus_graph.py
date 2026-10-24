#!/usr/bin/env python3
"""Convert an OpenStreetMap Overpass JSON download (ways with `out geom`)
into assets/maps/campus_graph.json (the outdoor walking graph).

Usage: python tools/build_campus_graph.py uhcl_paths.json assets/maps/campus_graph.json assets/maps/campus_buildings.geojson
Needs: python3, shapely  (pip install shapely)
The buildings file is used so that bridged gaps never cut through a building.

OpenStreetMap often leaves small gaps where paths meet or cross a road, so
the download comes in many separate pieces. Pieces within JOIN_METERS of
each other are joined at their closest points (splitting the path there),
closest pairs first, unless the straight link would cross a building.
Links longer than 25 m are guesses across unmapped ground and are listed so
they can be checked on the map. Pieces that stay unconnected are dropped and
reported.

Map data (c) OpenStreetMap contributors, ODbL.
"""
import json
import math
import sys
from collections import defaultdict, Counter

from shapely.geometry import LineString, Point, Polygon, shape
from shapely.ops import nearest_points, unary_union

WALKABLE = {"footway", "path", "pedestrian", "steps", "service", "living_street", "cycleway"}
import os
JOIN_METERS = float(os.environ.get("JOIN_METERS", "120"))   # longest gap that may be bridged
LAT0, LON0 = 29.578, -95.105
KX = 111320 * math.cos(math.radians(LAT0))
KY = 110574.0


def proj(lat, lon):
    return ((lon - LON0) * KX, (lat - LAT0) * KY)


def unproj(x, y):
    return (LAT0 + y / KY, LON0 + x / KX)


def load_obstacles(path):
    """Building footprints in meters (empty if no file is given)."""
    if not path:
        return None
    polys = []
    for f in json.load(open(path, encoding="utf-8"))["features"]:
        g = shape(f["geometry"])
        for p in (g.geoms if g.geom_type == "MultiPolygon" else [g]):
            ring = [proj(lat, lon) for lon, lat in p.exterior.coords]   # -> meters
            polys.append(Polygon(ring).buffer(0))
    return unary_union(polys)


def main(src, dst, buildings_path=None):
    obstacles = load_obstacles(buildings_path)
    with open(src, encoding="utf-8") as f:
        data = json.load(f)

    xy = {}                 # node id -> (x, y) meters
    edges = {}              # (a, b) sorted -> accessible (1/0)
    used = skipped = 0
    for el in data["elements"]:
        if el.get("type") != "way":
            continue
        tags = el.get("tags", {})
        if tags.get("highway") not in WALKABLE:
            continue
        if tags.get("access") in ("private", "no"):
            skipped += 1
            continue
        nodes, geom = el["nodes"], el["geometry"]
        if len(nodes) != len(geom):
            continue
        used += 1
        acc = 0 if tags.get("highway") == "steps" else 1
        for n, g in zip(nodes, geom):
            xy[n] = proj(g["lat"], g["lon"])
        for a, b in zip(nodes, nodes[1:]):
            if a != b:
                key = (a, b) if str(a) < str(b) else (b, a)
                edges[key] = min(edges.get(key, 1), acc)

    next_id = [0]

    def new_node(pt):
        next_id[0] += 1
        nid = "j%d" % next_id[0]
        xy[nid] = (pt.x, pt.y)
        return nid

    def components():
        adj = defaultdict(list)
        for a, b in edges:
            adj[a].append(b)
            adj[b].append(a)
        seen, comps = set(), []
        for s in adj:
            if s in seen:
                continue
            comp, stack = [], [s]
            seen.add(s)
            while stack:
                n = stack.pop()
                comp.append(n)
                for m in adj[n]:
                    if m not in seen:
                        seen.add(m)
                        stack.append(m)
            comps.append(comp)
        return comps

    def split_at(comp_nodes, pt):
        """Insert (or reuse) a node on the comp's edge nearest to pt."""
        cset = set(comp_nodes)
        best = None
        for (a, b) in edges:
            if a in cset:
                seg = LineString([xy[a], xy[b]])
                d = seg.distance(pt)
                if best is None or d < best[0]:
                    best = (d, a, b, seg)
        _, a, b, seg = best
        proj_pt = seg.interpolate(seg.project(pt))
        # reuse an end node when the closest point is (almost) at it
        for n in (a, b):
            if math.dist(xy[n], (proj_pt.x, proj_pt.y)) < 0.05:
                return n
        w = new_node(proj_pt)
        orig[w] = orig[a]
        acc = edges.pop((a, b))
        for u in (a, b):
            edges[(u, w) if str(u) < str(w) else (w, u)] = acc
        return w

    orig = {}
    for idx, comp in enumerate(components()):
        for n in comp:
            orig[n] = idx

    joins = 0
    long_joins = []
    blocked = set()
    while True:
        comps = components()
        if len(comps) == 1:
            break
        geoms = []
        for c in comps:
            cs = set(c)
            lines = [LineString([xy[a], xy[b]]) for (a, b) in edges if a in cs]
            geoms.append(lines)
        best = None
        # closest pair of pieces whose straight link does not cross a building
        from shapely.geometry import MultiLineString
        multi = [MultiLineString(g) for g in geoms]
        for i in range(len(comps)):
            for j in range(i + 1, len(comps)):
                d = multi[i].distance(multi[j])
                if d > JOIN_METERS or (best is not None and d >= best[0]):
                    continue
                pi_, pj_ = nearest_points(multi[i], multi[j])
                link = LineString([pi_, pj_])
                if obstacles is not None and d > 0.5 and link.intersection(obstacles).length > 2.0:
                    blocked.add((len(comps[i]), len(comps[j]), round(d)))
                    continue
                best = (d, i, j, pi_, pj_)
        if best is None:
            break
        _, i, j, pi, pj = best
        a = split_at(comps[i], pi)
        b = split_at(comps[j], pj)
        edges[(a, b) if str(a) < str(b) else (b, a)] = 1
        joins += 1
        if _ > 8:
            lat, lon = unproj(*xy[a])
            long_joins.append((round(_, 1), round(lat, 5), round(lon, 5)))

    # Second pass: even when everything is connected, add a short link between
    # two original pieces if walking between them is a big detour today.
    def graph_dist(src_n, dst_n):
        import heapq
        adj = defaultdict(list)
        for (a, b) in edges:
            w = math.dist(xy[a], xy[b])
            adj[a].append((b, w))
            adj[b].append((a, w))
        dist = {src_n: 0.0}
        heap = [(0.0, src_n)]
        while heap:
            d, u = heapq.heappop(heap)
            if u == dst_n:
                return d
            if d > dist.get(u, 1e18):
                continue
            for v, w in adj[u]:
                if d + w < dist.get(v, 1e18):
                    dist[v] = d + w
                    heapq.heappush(heap, (d + w, v))
        return 1e18

    from shapely.geometry import MultiLineString
    npieces = max(orig.values()) + 1
    cand = []
    lines0 = defaultdict(list)
    for (a, b) in edges:
        if orig.get(a) == orig.get(b) and a in orig:
            lines0[orig[a]].append(LineString([xy[a], xy[b]]))
    multi0 = {i: MultiLineString(l) for i, l in lines0.items()}
    for i in range(npieces):
        for j in range(i + 1, npieces):
            if i in multi0 and j in multi0:
                d = multi0[i].distance(multi0[j])
                if d <= JOIN_METERS:
                    cand.append((d, i, j))
    shortcuts = []
    for d, i, j in sorted(cand):
        lines_i = [LineString([xy[a], xy[b]]) for (a, b) in edges if orig.get(a) == i and orig.get(b) == i]
        lines_j = [LineString([xy[a], xy[b]]) for (a, b) in edges if orig.get(a) == j and orig.get(b) == j]
        mi, mj = MultiLineString(lines_i), MultiLineString(lines_j)
        pi, pj = nearest_points(mi, mj)
        d = pi.distance(pj)
        link = LineString([pi, pj])
        if obstacles is not None and d > 0.5 and link.intersection(obstacles).length > 2.0:
            continue
        na = min((n for n in orig if orig[n] == i), key=lambda n: math.dist(xy[n], (pi.x, pi.y)))
        nb = min((n for n in orig if orig[n] == j), key=lambda n: math.dist(xy[n], (pj.x, pj.y)))
        detour = graph_dist(na, nb)
        if detour > 2 * d + 100:
            a = split_at([n for n in orig if orig[n] == i], pi)
            b = split_at([n for n in orig if orig[n] == j], pj)
            edges[(a, b) if str(a) < str(b) else (b, a)] = 1
            lat, lon = unproj(*xy[a])
            shortcuts.append((round(d, 1), round(min(detour, 99999)), round(lat, 5), round(lon, 5)))

    comps = sorted(components(), key=len, reverse=True)
    keep = set(comps[0])
    dropped = comps[1:]

    node_list = sorted(keep, key=str)
    ids = {n: ("n%s" % n if not str(n).startswith("j") else str(n)) for n in node_list}
    out = {
        "version": 2,
        "source": "OpenStreetMap contributors (ODbL)",
        "nodes": [[ids[n], round(unproj(*xy[n])[0], 7), round(unproj(*xy[n])[1], 7)] for n in node_list],
        "edges": [[ids[a], ids[b], acc] for (a, b), acc in sorted(edges.items(), key=lambda kv: (str(kv[0][0]), str(kv[0][1])))
                  if a in keep and b in keep],
    }
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(out, f, separators=(",", ":"))

    print("ways used:", used, "| private skipped:", skipped)
    print("pieces joined:", joins)
    for d, lat, lon in long_joins:
        print("   joined across a %.1f m gap near lat %.5f lon %.5f" % (d, lat, lon))
    print("nodes:", len(out["nodes"]), "| edges:", len(out["edges"]))
    for d, det, lat, lon in shortcuts:
        print("   shortcut link of %.1f m near lat %.5f lon %.5f (walking there was %s m before)" % (d, lat, lon, det))
    if blocked:
        print("links skipped because they would cross a building:", sorted(blocked)[:8])
    print("pieces left unconnected (dropped):", len(dropped), "sizes", [len(c) for c in dropped][:10])
    for c in dropped[:6]:
        la = [unproj(*xy[n])[0] for n in c]
        lo = [unproj(*xy[n])[1] for n in c]
        print("   %3d nodes near lat %.4f lon %.4f" % (len(c), sum(la) / len(la), sum(lo) / len(lo)))


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
