import 'package:flutter/material.dart';

import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../passport/passport_studio_screen.dart';
import '../settings/settings_screen.dart';
import '../tools/tools_screen.dart';

/// Shared tab switching so other screens can jump between tabs.
final ValueNotifier<int> shellTab = ValueNotifier<int>(0);

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  static const _destinations = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.folder_open_outlined, Icons.folder, 'Documents'),
    (Icons.handyman_outlined, Icons.handyman, 'Tools'),
    (Icons.portrait_outlined, Icons.portrait, 'ID Photo'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: shellTab,
      builder: (context, index, _) {
        final body = IndexedStack(
          index: index,
          children: const [
            HomeScreen(),
            LibraryScreen(),
            ToolsScreen(),
            PassportStudioScreen(embedded: true),
            SettingsScreen(),
          ],
        );
        final wide = MediaQuery.sizeOf(context).width >= 840;
        if (wide) {
          return Scaffold(
            body: Row(children: [
              NavigationRail(
                selectedIndex: index,
                onDestinationSelected: (i) => shellTab.value = i,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ]),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => shellTab.value = i,
            destinations: [
              for (final d in _destinations) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
            ],
          ),
        );
      },
    );
  }
}
