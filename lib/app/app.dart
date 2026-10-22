import 'package:flutter/material.dart';

import '../views/home/home_screen.dart';
import '../views/shared/placeholder_screen.dart';
import '../theme/app_theme.dart';
import '../views/directions/directions_screen.dart';
import '../views/settings/settings_screen.dart';

class CampusNavigationApp extends StatelessWidget {
  const CampusNavigationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UHCL Campus Navigation',
      debugShowCheckedModeBanner: false,

      theme: AppTheme.lightTheme,

      initialRoute: '/',

      routes: {
        '/': (context) => const HomeScreen(),

        // '/search': (context) => const PlaceholderScreen(
        //   title: 'Campus Search',
        //   message: 'Campus location search will be implemented here.',
        // ),
        '/route': (context) => const PlaceholderScreen(
          title: 'Route',
          message: 'Generated route information will appear here.',
        ),

        '/directions': (context) => const DirectionsScreen(),

        '/settings': (context) => const SettingsScreen(),

        '/report': (context) => const PlaceholderScreen(
          title: 'Report an Issue',
          message: 'Campus navigation issue reporting will appear here.',
        ),
      },
    );
  }
}
