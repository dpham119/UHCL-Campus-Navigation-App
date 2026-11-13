# UHCL-Campus-Navigation-App
UHCL PathFinder

UHCL PathFinder is a campus navigation app for the University of Houston-Clear Lake (UHCL). It gives walking directions across campus and inside the buildings, down to the room, and it has an accessible mode that avoids stairs.

This is our senior capstone project. We built it with Flutter, UHCL's own campus map data (ArcGIS), and a routing engine that we wrote ourselves instead of calling a maps service.

<!-- Add screenshots here, for example: ![Route to a room](docs/route.png) -->
Why we built it

Google Maps and Apple Maps get you to the front of a building, then stop. Finding the right room on the second or third floor of a big building is the hard part, especially for new students, visitors, and anyone who cannot use stairs. We wanted one app that handles the whole trip: parking lot, sidewalk, front door, hallway, elevator, room.

What it does
Search for buildings, rooms, and other locations from one search bar.
Indoor and outdoor routes in one trip. Pick a start and a destination, and the route runs along the campus walkways, through the entrance, and down the hallways to the room.
Floor switching. Each floor has its own map layer. A route is split by floor, and you can flip between floors to see each part.
Accessible routing. With the Accessible switch on, routes never use stairs and use elevators to change floors. Outdoor walkways work the same either way. If no accessible route exists, the app says so.
Best entrance for a building. If the destination is a whole building, the route ends at whichever entrance is closest on the way in, instead of always using one door.
Live GPS. Use your current location as the start and follow your position along the route.
Distance and walking time for every route.
Report an issue, for example when an elevator is out of service.
Settings for map labels, distance units, and other options.
How it works

The whole app is built on one idea: campus is a graph.

Nodes are points you can stand on: sidewalk intersections, building entrances, hallway points, rooms, stairs, and elevators.
Edges are the walkable connections between nodes. Each has a length in meters and an accessible flag.
Routes are found with Dijkstra's shortest path algorithm (lib/routing/route_generator.dart).

The outdoor graph has about 2,000 nodes, and the indoor graph has about 6,500.

Accessible mode is not a second routing engine. It is a filter on the same graph: when it is on, the generator skips any edge that is marked inaccessible or that touches a stairs node. Elevators are linked between floors, so the same search finds the elevator route automatically.

Buildings and rooms. Rooms can have more than one door, and buildings can have more than one entrance. We try every combination and keep the shortest route. When the destination is a whole building, the building's hallways are blocked for that route, so it stops at the door instead of walking through the building.

Where the data comes from
Floor plans, buildings, and rooms: UHCL's campus GIS data (ArcGIS), stored as GeoJSON in assets/maps/.
Base map: OpenStreetMap tiles.
The graphs: generated from the GIS data by Python scripts in tools/.
build_indoor_graph.py turns each floor plan's hallways, stairs, elevators, and rooms into the indoor graph.
build_walkway_graph.py turns the campus sidewalks into the outdoor graph.
align_layers.py shifts the GIS layers slightly so they line up with OpenStreetMap.
door_hints.json holds a few hand-placed doors, stairs, and elevators that are missing from the data.

Currently the indoor map covers the Arbor, Bayou, Delta, Student Services and Classroom, STEM and Classroom, and Recreation and Wellness buildings.

Tech stack
Flutter / Dart (Android, iOS, and web)
flutter_map and latlong2 for the map
geolocator for GPS
Python (shapely, numpy, scipy) for building the graph data
Firebase Hosting for the web build (firebase.json)
Project layout
lib/
  app/            app shell, routes, and theme setup
  routing/        the graph, Dijkstra route generator, entrance and indoor helpers
  services/       location (GPS) service
  views/
    home/         home screen with search and the Accessible switch
    map/          the campus map, route display, and floor layers
    directions/   directions screen
    settings/     settings screen
assets/
  maps/           GeoJSON floor plans and the generated graph files
  icon/           app icon artwork
tools/            Python scripts that build the graphs from the GIS data
test/             unit tests for routing
Getting started

You need the Flutter SDK installed.

bash
git clone https://github.com/dpham119/UHCL-Campus-Navigation-App.git
cd UHCL-Campus-Navigation-App
flutter pub get
flutter run

Pick a device when Flutter asks: an Android emulator, an iOS simulator, a phone, or Chrome for the web version.

For live GPS, allow location access when the app asks. The app still works for searching and routing without it.

Running the tests
bash
flutter analyze
flutter test

The routing tests cover the shortest-path search, the accessible filter (no stairs, elevators allowed), entrance selection for buildings, and multi-floor routes on the real campus data.