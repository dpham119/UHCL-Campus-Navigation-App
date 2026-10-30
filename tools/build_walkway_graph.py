#!/usr/bin/env python3
"""Build the outdoor walking graph (assets/maps/campus_graph.json) from the campus sidewalk shapes
(assets/maps/campus_walkways.geojson) instead of OpenStreetMap lines.

Usage: python tools/build_walkway_graph.py assets/maps/campus_walkways.geojson assets/maps/campus_graph.json [old_campus_graph.json]
The optional old graph (from git) supplies the roads between the shapes.
Needs: python3, shapely, numpy, scipy (and tools/build_indoor_graph.py next to it, for the centerline code).

In the file, the first outline is the outer edge of the sidewalk network and the second is the ground enclosed
by it, so the sidewalks are the first minus the second (the pale lines on the map). The centerline of each
sidewalk becomes the graph; nodes sit where sidewalks meet and about every 8 m along them. Pieces that do not
touch (a road crossing, a gap in the data) are joined by a straight link if they are within BRIDGE_M."""
import json, math, os, sys, importlib.util
from collections import defaultdict, Counter
from shapely.geometry import Polygon, LineString, Point, box, shape
from shapely.ops import unary_union
from scipy.spatial import cKDTree

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ib", os.path.join(here, "build_indoor_graph.py"))
ib = importlib.util.module_from_spec(spec); spec.loader.exec_module(ib)
ib.SKEL_SPUR_M = 3.0
ib.SKEL_SIMPLIFY = 0.4
ib.SKEL_MAX_EDGE = 8.0
BBOX = (-95.125, 29.565, -95.085, 29.600)
BRIDGE_M = 120.0
SHORTCUT_M = 45.0
EDGE_OUT = 2.5        # width of the band outside a shape's border that counts as its sidewalk
EDGE_IN = 0.5
GAP_MAX = 12.0        # gaps between shapes up to this wide are sidewalks


def main(walk, dst, old=None):
    shapes = []
    for f in json.load(open(walk, encoding="utf-8"))["features"]:
        g = f["geometry"]
        for p in (g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]):
            lon, lat = p[0][0][:2]
            if BBOX[0] < lon < BBOX[2] and BBOX[1] < lat < BBOX[3] or True:
                shapes.append(Polygon([ib.proj(lo, la) for lo, la in p[0]]).buffer(0))
    shapes.sort(key=lambda q: -q.area)
    outer, inner, blocks = shapes[0], shapes[1], [q for q in shapes[2:] if q.area < 100000]
    U = unary_union(blocks)
    # On the map every shape is drawn with the same translucent fill, so the lightest color is the paths:
    # inside the outer outline, outside the second outline and outside every other shape. Parking lots
    # and buildings are cut out.
    folder = os.path.dirname(os.path.abspath(walk))
    def footprints(name):
        path = os.path.join(folder, name)
        out = []
        if os.path.exists(path):
            for f in json.load(open(path, encoding="utf-8"))["features"]:
                g = shape(f["geometry"])
                for q in (g.geoms if g.geom_type == "MultiPolygon" else [g]):
                    out.append(Polygon([ib.proj(lo, la) for lo, la in q.exterior.coords]).buffer(0))
        return out
    blds = footprints("campus_buildings.geojson")
    lots = footprints("campus_parking.geojson")
    Bu = unary_union(blds) if blds else Polygon()
    area = outer.difference(inner).difference(U).difference(unary_union(lots) if lots else Polygon())
    area = area.difference(Bu.buffer(0.3)).buffer(0.2).buffer(-0.2).buffer(0)
    x0, y0 = ib.proj(BBOX[0], BBOX[1]); x1, y1 = ib.proj(BBOX[2], BBOX[3])
    area = area.intersection(box(x0, y0, x1, y1))
    print("path area %.0f m2" % area.area)
    pts, edges = ib.clean_skeleton(ib.skeleton_edges(area), None, None)
    xy = list(pts)
    # the old OpenStreetMap paths are kept only outside the walkway shapes (the road between the two
    # parts of campus); inside the shapes they are replaced by the sidewalks above
    n_old = 0
    if old:
        from shapely.prepared import prep
        zone = prep(U.buffer(EDGE_OUT + 1.0))
        od = json.load(open(old, encoding="utf-8"))
        pos = {}
        for nid_, la, lo in od["nodes"]:
            p = ib.proj(lo, la)
            if not zone.contains(Point(p)):
                pos[nid_] = len(xy); xy.append(p)
        for a, b, *_ in od["edges"]:
            if a in pos and b in pos:
                edges.append((pos[a], pos[b])); n_old += 1
    print("old paths kept outside the shapes: %d edges" % n_old)
    # shortcuts: two path points that can see each other across open ground (not through a building and
    # not through the inside of a walkway shape) are joined, so a route never detours around a corner
    from shapely.prepared import prep as _prep
    free = _prep(area.buffer(0.3))
    have = {tuple(sorted(e)) for e in edges}
    tr = cKDTree(xy)
    n_short = 0
    for i, j in sorted(tr.query_pairs(SHORTCUT_M)):
        if (i, j) in have: continue
        if free.contains(LineString([xy[i], xy[j]])):
            edges.append((i, j)); n_short += 1
    print("shortcuts across open ground: %d" % n_short)
    adj = defaultdict(set)
    for a, b in edges:
        adj[a].add(b); adj[b].add(a)

    def comps():
        seen, out = set(), []
        for s in adj:
            if s in seen: continue
            st, c = [s], []; seen.add(s)
            while st:
                n = st.pop(); c.append(n)
                for m in adj[n]:
                    if m not in seen: seen.add(m); st.append(m)
            out.append(c)
        return out
    n_bridge = 0
    while True:
        cs = comps()
        if len(cs) < 2: break
        owner = {n: i for i, c in enumerate(cs) for n in c}
        tree = cKDTree([xy[n] for n in range(len(xy))])
        best = None
        for i, c in enumerate(cs):
            for n in c:
                for j in tree.query_ball_point(xy[n], BRIDGE_M):
                    if j in owner and owner[j] != i:
                        d = math.dist(xy[n], xy[j])
                        if best is None or d < best[0]: best = (d, n, j)
        if best is None: break
        d, n, j = best
        adj[n].add(j); adj[j].add(n); edges.append((n, j)); n_bridge += 1
        if d > 25:
            la, lo = ib.unproj(*xy[n]); print("  long link %.0f m near lat %.5f lon %.5f" % (d, la, lo))
    cs = sorted(comps(), key=len, reverse=True)
    keep = sorted(cs[0])
    nid = {n: "n%d" % (k + 1) for k, n in enumerate(keep)}
    out = {"version": 2, "source": "UHCL campus sidewalk shapes (campus_walkways.geojson)",
           "nodes": [[nid[n], round(ib.unproj(*xy[n])[0], 7), round(ib.unproj(*xy[n])[1], 7)] for n in keep],
           "edges": [[nid[a], nid[b], 1] for a, b in sorted({tuple(sorted(e)) for e in edges}) if a in nid and b in nid]}
    json.dump(out, open(dst, "w"), separators=(",", ":"))
    print("bridged %d gaps; dropped pieces: %s" % (n_bridge, [len(c) for c in cs[1:]]))
    print("graph: %d nodes, %d edges" % (len(out["nodes"]), len(out["edges"])))


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4): sys.exit(__doc__)
    main(*sys.argv[1:])
