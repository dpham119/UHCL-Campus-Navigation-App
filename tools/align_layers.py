#!/usr/bin/env python3
"""Line the campus GIS layers up with the OpenStreetMap base map.

The UHCL GIS files sit about 3 m south-west of the OpenStreetMap tiles, and some building and parking outlines
differ in shape. This script (1) moves every GIS layer by one shift, so they all stay in step with each other
(buildings, parking, walkways, floor plans, the indoor graph and the outdoor graph), and (2) replaces each building
and parking outline with the matching OpenStreetMap outline where there is one.

Usage: python tools/align_layers.py assets/maps tools/osm_buildings.json [dx_m dy_m]
  assets/maps         folder with the GIS files (they are rewritten in place: run it ONCE on the original files)
  tools/osm_buildings.json   Overpass JSON ("out geom") of the buildings and parking in the campus area
  dx_m dy_m           shift in meters east / north (default 1.35 2.65, fitted to the OSM buildings)
tools/build_indoor_graph.py already uses the same shifted origin, so its door hints keep working.
Needs: python3, shapely."""
import json, math, os, sys
from shapely.geometry import Polygon, MultiPolygon, shape, mapping
from shapely.ops import unary_union

LAT0, LON0 = 29.578, -95.105
KY = 110574.0
KX = 111320 * math.cos(math.radians(LAT0))
BBOX = (-95.125, 29.565, -95.085, 29.600)


def main(folder, osm_path, dx=1.35, dy=2.65):
    dlon, dlat = dx / KX, dy / KY
    def sh(c):                                   # [lon, lat(, z)] -> shifted
        return [round(c[0] + dlon, 9), round(c[1] + dlat, 9)] + list(c[2:])
    def shift_geom(g):
        t = g["type"]
        if t == "Polygon":
            return {"type": t, "coordinates": [[sh(c) for c in r] for r in g["coordinates"]]}
        if t == "MultiPolygon":
            return {"type": t, "coordinates": [[[sh(c) for c in r] for r in p] for p in g["coordinates"]]}
        return g
    def p(name): return os.path.join(folder, name)

    # 1. shift
    for name in ("campus_buildings", "campus_parking", "campus_walkways", "campus_first_floor",
                 "campus_second_floor", "campus_third_floor"):
        d = json.load(open(p(name + ".geojson"), encoding="utf-8"))
        for f in d["features"]:
            f["geometry"] = shift_geom(f["geometry"])
        json.dump(d, open(p(name + ".geojson"), "w", encoding="utf-8"), separators=(",", ":"))
    d = json.load(open(p("campus_indoor_graph.json"), encoding="utf-8"))
    for n in d["nodes"]:
        n[0] = round(n[0] + dlat, 7); n[1] = round(n[1] + dlon, 7)
        if len(n) > 6:
            n[5] = round(n[5] + dlat, 7); n[6] = round(n[6] + dlon, 7)
    d["footprints"] = [[b, [[[round(a + dlat, 7), round(o + dlon, 7)] for a, o in ring] for ring in rings]] for b, rings in d["footprints"]]
    json.dump(d, open(p("campus_indoor_graph.json"), "w", encoding="utf-8"), separators=(",", ":"))
    d = json.load(open(p("campus_graph.json"), encoding="utf-8"))
    for n in d["nodes"]:
        n[1] = round(n[1] + dlat, 7); n[2] = round(n[2] + dlon, 7)
    json.dump(d, open(p("campus_graph.json"), "w", encoding="utf-8"), separators=(",", ":"))

    # 2. snap building and parking outlines to OpenStreetMap
    osm = json.load(open(osm_path, encoding="utf-8"))
    shapes = {"b": [], "p": []}
    for e in osm["elements"]:
        g = e.get("geometry")
        if not g or len(g) < 4: continue
        if not (BBOX[0] < g[0]["lon"] < BBOX[2] and BBOX[1] < g[0]["lat"] < BBOX[3]): continue
        kind = "b" if "building" in e.get("tags", {}) else "p"
        poly = Polygon([(n["lon"], n["lat"]) for n in g]).buffer(0)
        if poly.area > 0: shapes[kind].append(poly)
    for name, kind in (("campus_buildings", "b"), ("campus_parking", "p")):
        d = json.load(open(p(name + ".geojson"), encoding="utf-8"))
        swapped = kept = 0
        for f in d["features"]:
            F = shape(f["geometry"])
            if F.is_empty or not (BBOX[0] < F.representative_point().x < BBOX[2]): continue
            used = [c for c in shapes[kind] if c.intersection(F).area / c.area >= 0.4]
            if used and 0.6 <= sum(c.area for c in used) / F.area <= 1.8:
                geom = unary_union(used)
                f["geometry"] = mapping(geom)
                swapped += 1
            else:
                kept += 1
                print("  kept GIS outline:", f["properties"].get("BuildingName") or f["properties"].get("Name") or f["properties"])
        json.dump(d, open(p(name + ".geojson"), "w", encoding="utf-8"), separators=(",", ":"))
        print("%s: %d outlines replaced by OpenStreetMap, %d kept" % (name, swapped, kept))
    print("shifted everything by %.2f m east, %.2f m north" % (dx, dy))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) not in (2, 4): sys.exit(__doc__)
    main(a[0], a[1], *(float(x) for x in a[2:]))
