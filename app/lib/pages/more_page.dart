import 'package:flutter/material.dart';

import '../config.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import 'alerts_page.dart';
import 'community_forum_page.dart';
import 'support_page.dart';

class MorePage extends StatefulWidget {
  const MorePage({super.key});

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  late final Future<Map<String, dynamic>> _profile = AuthService.instance.profile();

  void _open(Widget page) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Log out')),
        ],
      ),
    );
    if (ok == true) await AuthService.instance.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.instance.currentUser;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: _profile,
                    builder: (context, snap) {
                      final p = snap.data ?? const {};
                      final name = (p['username'] as String?) ??
                          user?.displayName ??
                          'Pet owner';
                      final flag = (p['flag'] as String?) ?? '';
                      return ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        leading: CircleAvatar(
                          radius: 26,
                          backgroundColor:
                              AppTheme.primaryColor.withValues(alpha: 0.15),
                          child: Text(
                            name.isEmpty ? '?' : name[0].toUpperCase(),
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.primaryColor),
                          ),
                        ),
                        title: Text(name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 18)),
                        subtitle: Text(
                            '${user?.email ?? ''}${flag.isEmpty ? '' : '\n$flag'}'),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.notifications_outlined),
                        title: const Text('Alerts'),
                        subtitle: const Text('Temperature, water, food and device warnings'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(const AlertsPage()),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.forum_outlined),
                        title: const Text('Community forum'),
                        subtitle: const Text('Ask questions and share pet care tips'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(const CommunityForumPage()),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.support_agent_outlined),
                        title: const Text('Feedback & support'),
                        subtitle: const Text('Report a bug or hardware problem'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(const SupportPage()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      ValueListenableBuilder<ThemeMode>(
                        valueListenable: themeController,
                        builder: (context, mode, _) => SwitchListTile(
                          secondary: const Icon(Icons.dark_mode_outlined),
                          title: const Text('Dark mode'),
                          value: mode == ThemeMode.dark,
                          onChanged: (_) => themeController.toggle(),
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: const Text('About'),
                        onTap: () => showAboutDialog(
                          context: context,
                          applicationName: 'Smart Pet Monitor',
                          applicationVersion: '2.0.0',
                          applicationIcon:
                              const Icon(Icons.pets, color: AppTheme.primaryColor),
                          children: const [
                            Text(
                              'Smart Pet Monitoring System with IoT-Based Environmental Control.\n\n'
                              'ESP32 (sensors & actuators) + Raspberry Pi 3 (YOLOv11n pet recognition) '
                              '+ MQTT + Firebase + Flutter.\n\n'
                              'Final Year Project, Faculty of Computing and Informatics, '
                              'Universiti Malaysia Sabah.\n\n'
                              'Device: ${AppConfig.deviceId}',
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.logout, color: AppTheme.danger),
                        title: const Text('Log out',
                            style: TextStyle(color: AppTheme.danger)),
                        onTap: _logout,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
