import 'package:flutter/material.dart';

import '../models/feeder_models.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  final _service = NotificationService.instance;
  late final Stream<List<AlertItem>> _alerts = _service.alerts();
  List<AlertItem> _latest = const [];

  ({IconData icon, Color color}) _style(String type) {
    switch (type) {
      case 'temperature':
        return (icon: Icons.thermostat, color: AppTheme.temp);
      case 'water':
        return (icon: Icons.water_drop, color: AppTheme.water);
      case 'food':
        return (icon: Icons.no_food_outlined, color: AppTheme.food);
      case 'pet':
        return (icon: Icons.pets, color: Colors.deepPurple);
      case 'device':
        return (icon: Icons.wifi_off, color: AppTheme.danger);
      default:
        return (icon: Icons.notifications, color: Colors.blueGrey);
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all alerts?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await runWithFeedback(context, _service.clearAll, success: 'Alerts cleared');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
            onPressed: () => _service.markAllRead(_latest),
          ),
          IconButton(
            tooltip: 'Clear all',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearAll,
          ),
        ],
      ),
      body: StreamBuilder<List<AlertItem>>(
        stream: _alerts,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
                child: EmptyState(
                    icon: Icons.error_outline,
                    title: 'Could not load alerts',
                    message: snap.error.toString()));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final alerts = snap.data!;
          _latest = alerts;
          if (alerts.isEmpty) {
            return const Center(
              child: EmptyState(
                icon: Icons.notifications_none,
                title: 'All quiet',
                message: 'You will be alerted about high temperature, low water, '
                    'empty food hoppers and unknown animals.',
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: alerts.length,
            separatorBuilder: (_, i) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final a = alerts[i];
              final s = _style(a.type);
              return PageBody(
                maxWidth: 800,
                child: Card(
                  color: a.read
                      ? null
                      : s.color.withValues(alpha: 0.08),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: CircleAvatar(
                      backgroundColor: s.color.withValues(alpha: 0.15),
                      child: Icon(s.icon, color: s.color),
                    ),
                    title: Text(a.title,
                        style: TextStyle(
                            fontWeight: a.read ? FontWeight.w600 : FontWeight.w800)),
                    subtitle: Text('${a.message}\n${timeAgo(a.time)}'),
                    isThreeLine: true,
                    trailing: a.read
                        ? null
                        : const Icon(Icons.circle, size: 10, color: AppTheme.primaryColor),
                    onTap: a.read ? null : () => _service.markRead(a),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
