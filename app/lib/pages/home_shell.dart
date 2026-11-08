import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import 'alerts_page.dart';
import 'dashboard_page.dart';
import 'feeder_control_page.dart';
import 'history_page.dart';
import 'more_page.dart';
import 'pet_profile_page.dart';

class _Destination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const _Destination(this.label, this.icon, this.selectedIcon);
}

const _destinations = [
  _Destination('Dashboard', Icons.space_dashboard_outlined, Icons.space_dashboard),
  _Destination('Feeder', Icons.tune_outlined, Icons.tune),
  _Destination('Pets', Icons.pets_outlined, Icons.pets),
  _Destination('History', Icons.insights_outlined, Icons.insights),
  _Destination('More', Icons.menu, Icons.menu_open),
];

/// Main app frame: bottom navigation on phones, side rail on tablets / web.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final pages = <Widget>[
      DashboardPage(onNavigate: _goTo),
      const FeederControlPage(),
      const PetProfilePage(),
      const HistoryPage(),
      const MorePage(),
    ];

    final body = IndexedStack(index: _index, children: pages);

    final appBar = AppBar(
      title: Text(_index == 0 ? 'Smart Pet Monitor' : _destinations[_index].label),
      actions: [
        const _AlertsButton(),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: themeController,
          builder: (context, mode, _) => IconButton(
            tooltip: mode == ThemeMode.dark ? 'Light mode' : 'Dark mode',
            onPressed: themeController.toggle,
            icon: Icon(mode == ThemeMode.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
          ),
        ),
        const SizedBox(width: 8),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: MediaQuery.sizeOf(context).width >= 1200,
              selectedIndex: _index,
              onDestinationSelected: _goTo,
              labelType: MediaQuery.sizeOf(context).width >= 1200
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                  child: const Icon(Icons.pets, color: AppTheme.primaryColor),
                ),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Scaffold(appBar: appBar, body: body),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// Bell icon with unread-alert badge. Owns its own stream so it can move
/// between the phone and wide layouts safely.
class _AlertsButton extends StatefulWidget {
  const _AlertsButton();

  @override
  State<_AlertsButton> createState() => _AlertsButtonState();
}

class _AlertsButtonState extends State<_AlertsButton> {
  final Stream<int> _unread = NotificationService.instance.unreadCount();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _unread,
      builder: (context, snap) {
        final count = snap.data ?? 0;
        return IconButton(
          tooltip: 'Alerts',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AlertsPage()),
          ),
          icon: Badge(
            isLabelVisible: count > 0,
            label: Text(count > 99 ? '99+' : '$count'),
            child: const Icon(Icons.notifications_outlined),
          ),
        );
      },
    );
  }
}
