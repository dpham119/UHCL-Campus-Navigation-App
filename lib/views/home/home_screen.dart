import 'package:flutter/material.dart';

import '../map/campus_map_view.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool accessibilityRouting = false;

  final GlobalKey<CampusMapViewState> _mapKey = GlobalKey<CampusMapViewState>();

  void _openDirections() {
    Navigator.pushNamed(context, '/directions');
  }

  void _openSettings() {
    Navigator.pushNamed(context, '/settings');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        child: Stack(
          children: [
            // FULL-SCREEN CAMPUS MAP
            Positioned.fill(child: CampusMapView(key: _mapKey)),

            // SEARCH BAR OVER THE MAP
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Material(
                  elevation: 5,
                  borderRadius: BorderRadius.circular(18),
                  child: TextField(
                    readOnly: true,
                    onTap: () {
                      _mapKey.currentState?.openSearch();
                    },
                    decoration: InputDecoration(
                      hintText: 'Search buildings, rooms, or locations',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),

      // BOTTOM NAVIGATION BAR
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              // MAP
              Expanded(
                child: _BottomNavigationItem(
                  icon: Icons.map,
                  label: 'Map',
                  selected: true,
                  onTap: () {
                    // Already on the map screen.
                  },
                ),
              ),

              // DIRECTIONS
              Expanded(
                child: _BottomNavigationItem(
                  icon: Icons.directions_outlined,
                  label: 'Directions',
                  onTap: _openDirections,
                ),
              ),

              // ACCESSIBLE ROUTING
              Expanded(
                child: _AccessibilityNavigationItem(
                  enabled: accessibilityRouting,
                  onChanged: (value) {
                    setState(() {
                      accessibilityRouting = value;
                    });
                     _mapKey.currentState?.setAccessibleOnly(value);
                    // Later this value can be passed
                    // to the routing engine.
                  },
                ),
              ),

              // SETTINGS
              Expanded(
                child: _BottomNavigationItem(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  onTap: _openSettings,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavigationItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _BottomNavigationItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessibilityNavigationItem extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _AccessibilityNavigationItem({
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 32,
          child: FittedBox(
            fit: BoxFit.fill,
            child: Switch(value: enabled, onChanged: onChanged),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Accessible',
          style: TextStyle(
            fontSize: 11,
            fontWeight: enabled ? FontWeight.bold : FontWeight.normal,
            color: enabled
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
