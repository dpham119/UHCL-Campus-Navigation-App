import 'package:flutter/material.dart';

class DirectionStep {
  final IconData icon;
  final String instruction;
  final String? detail;

  const DirectionStep({
    required this.icon,
    required this.instruction,
    this.detail,
  });
}

class DirectionsScreen extends StatelessWidget {
  const DirectionsScreen({super.key});

  static const List<DirectionStep> sampleSteps = [
    DirectionStep(
      icon: Icons.directions_walk,
      instruction: 'Start walking east on University Drive.',
      detail: 'Continue for approximately 300 ft.',
    ),
    DirectionStep(
      icon: Icons.turn_left,
      instruction: 'Turn left toward Bayou Road East.',
      detail: 'Continue along the pedestrian walkway.',
    ),
    DirectionStep(
      icon: Icons.turn_right,
      instruction: 'Turn right at Bayou Road East.',
      detail: 'Continue for approximately 0.2 miles.',
    ),
    DirectionStep(
      icon: Icons.turn_left,
      instruction: 'Turn left toward the parking lot.',
      detail: 'Use the marked pedestrian path.',
    ),
    DirectionStep(
      icon: Icons.directions_walk,
      instruction: 'Continue toward the building entrance.',
      detail: 'The destination will be ahead on your right.',
    ),
    DirectionStep(
      icon: Icons.location_on,
      instruction: 'You have arrived at your destination.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Directions')),

      body: Column(
        children: [
          // ROUTE SUMMARY
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Current Route',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),

                const SizedBox(height: 8),

                const Row(
                  children: [
                    Icon(Icons.trip_origin, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Current Location',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),

                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(height: 22, child: VerticalDivider(width: 2)),
                ),

                const Row(
                  children: [
                    Icon(Icons.location_on, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Selected Destination',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                Row(
                  children: [
                    _RouteInfo(
                      icon: Icons.directions_walk,
                      value: '0.6 mi',
                      label: 'Distance',
                    ),
                    const SizedBox(width: 28),
                    _RouteInfo(
                      icon: Icons.schedule,
                      value: '12 min',
                      label: 'Walking time',
                    ),
                  ],
                ),
              ],
            ),
          ),

          // TITLE
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 20, 18, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Step-by-Step Directions',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ),

          // WRITTEN DIRECTIONS
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              itemCount: sampleSteps.length,
              separatorBuilder: (context, index) {
                return const SizedBox(height: 8);
              },
              itemBuilder: (context, index) {
                final step = sampleSteps[index];

                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            step.icon,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),

                        const SizedBox(width: 14),

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                step.instruction,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),

                              if (step.detail != null) ...[
                                const SizedBox(height: 5),
                                Text(
                                  step.detail!,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteInfo extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _RouteInfo({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
