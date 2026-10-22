import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool showMapLabels = true;
  bool keepMapCentered = false;
  bool highContrast = false;
  bool largeText = false;

  String distanceUnit = 'Miles';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),

      body: ListView(
        children: [
          const _SettingsSectionTitle(title: 'Navigation'),

          SwitchListTile(
            secondary: const Icon(Icons.label_outline),
            title: const Text('Map Labels'),
            subtitle: const Text('Show building and room labels on the map'),
            value: showMapLabels,
            onChanged: (value) {
              setState(() {
                showMapLabels = value;
              });
            },
          ),

          SwitchListTile(
            secondary: const Icon(Icons.my_location),
            title: const Text('Keep Map Centered'),
            subtitle: const Text(
              'Keep the map centered on your location while navigating',
            ),
            value: keepMapCentered,
            onChanged: (value) {
              setState(() {
                keepMapCentered = value;
              });
            },
          ),

          ListTile(
            leading: const Icon(Icons.straighten),
            title: const Text('Distance Units'),
            subtitle: Text(distanceUnit),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              _showDistanceUnitDialog();
            },
          ),

          const Divider(),

          const _SettingsSectionTitle(title: 'Accessibility'),

          SwitchListTile(
            secondary: const Icon(Icons.contrast),
            title: const Text('High Contrast'),
            subtitle: const Text('Increase contrast for improved readability'),
            value: highContrast,
            onChanged: (value) {
              setState(() {
                highContrast = value;
              });
            },
          ),

          SwitchListTile(
            secondary: const Icon(Icons.text_fields),
            title: const Text('Larger Text'),
            subtitle: const Text('Use larger text throughout the application'),
            value: largeText,
            onChanged: (value) {
              setState(() {
                largeText = value;
              });
            },
          ),

          const Divider(),

          const _SettingsSectionTitle(title: 'Permissions & Privacy'),

          const ListTile(
            leading: Icon(Icons.location_on_outlined),
            title: Text('Location Permission'),
            subtitle: Text('Required to determine your current location'),
            trailing: Icon(Icons.chevron_right),
          ),

          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Privacy'),
            subtitle: Text(
              'View information about location and application data',
            ),
            trailing: Icon(Icons.chevron_right),
          ),

          const Divider(),

          const _SettingsSectionTitle(title: 'About'),

          const ListTile(
            leading: Icon(Icons.help_outline),
            title: Text('Help'),
            subtitle: Text('Learn how to use campus navigation features'),
            trailing: Icon(Icons.chevron_right),
          ),

          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('About Campus Navigation'),
            subtitle: Text('UHCL Campus Navigation App'),
          ),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  void _showDistanceUnitDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Distance Units'),
          content: RadioGroup<String>(
            groupValue: distanceUnit,
            onChanged: (value) {
              if (value == null) return;

              setState(() {
                distanceUnit = value;
              });

              Navigator.pop(context);
            },
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(value: 'Miles', title: Text('Miles')),
                RadioListTile<String>(
                  value: 'Kilometers',
                  title: Text('Kilometers'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  final String title;

  const _SettingsSectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 6),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
