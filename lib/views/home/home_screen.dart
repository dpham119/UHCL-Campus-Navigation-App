import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool accessibilityRouting = false;

  void _openBottomNavigationItem(BuildContext context, int index) {
    switch (index) {
      case 0:
        // Already on the map screen.
        break;

      case 1:
        Navigator.pushNamed(context, '/directions');
        break;

      case 2:
        Navigator.pushNamed(context, '/settings');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('UHCL Campus Navigation'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'route') {
                Navigator.pushNamed(context, '/route');
              }

              if (value == 'report') {
                Navigator.pushNamed(context, '/report');
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'route',
                child: Row(
                  children: [
                    Icon(Icons.route),
                    SizedBox(width: 12),
                    Text('Route View'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(Icons.report_outlined),
                    SizedBox(width: 12),
                    Text('Report an Issue'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),

      body: SafeArea(
        child: Column(
          children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                readOnly: true,
                onTap: () {
                  Navigator.pushNamed(context, '/search');
                },
                decoration: InputDecoration(
                  hintText: 'Search buildings, rooms, or locations',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: const Icon(Icons.arrow_forward),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),

            // Map placeholder
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.map_outlined, size: 72),
                        SizedBox(height: 16),
                        Text(
                          'UHCL Campus Map',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text('ArcGIS map will be displayed here'),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Accessibility toggle
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                child: SwitchListTile(
                  value: accessibilityRouting,
                  onChanged: (value) {
                    setState(() {
                      accessibilityRouting = value;
                    });
                  },
                  secondary: Icon(
                    Icons.accessible,
                    color: accessibilityRouting
                        ? Theme.of(context).colorScheme.secondary
                        : null,
                  ),
                  title: const Text(
                    'Accessible Routing',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    accessibilityRouting
                        ? 'Prioritize ramps, elevators, and accessible paths'
                        : 'Use standard campus routes',
                  ),
                ),
              ),
            ),

            // Main route controls
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        // GPS functionality will be implemented later.
                      },
                      icon: const Icon(Icons.my_location),
                      label: const Text('My Location'),
                    ),
                  ),

                  const SizedBox(width: 12),

                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pushNamed(context, '/route');
                      },
                      icon: const Icon(Icons.directions_walk),
                      label: const Text('Get Directions'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),

      // Search removed from bottom navigation
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          _openBottomNavigationItem(context, index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_outlined),
            label: 'Directions',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
