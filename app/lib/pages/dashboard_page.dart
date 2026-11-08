import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/feeder_models.dart';
import '../models/pet.dart';
import '../services/auth_service.dart';
import '../services/feeder_service.dart';
import '../services/pet_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'feed_dialog.dart';
import 'live_view_page.dart';

class DashboardPage extends StatefulWidget {
  /// Lets the dashboard jump to another tab (e.g. "Manage pets").
  final ValueChanged<int>? onNavigate;

  const DashboardPage({super.key, this.onNavigate});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _feeder = FeederService.instance;
  late final Stream<DeviceStatus> _status = _feeder.statusStream();
  late final Stream<FeederConfig> _config = _feeder.configStream();
  late final Stream<List<LogEntry>> _logs = _feeder.logsStream(limit: 60);
  late final Stream<List<Pet>> _pets = PetRepository.instance.petsStream();
  String _username = '';
  bool _demoMode = false;

  // Firebase only sends data when something changes. If the feeder loses power
  // nothing changes, so redraw every 10 s to update "online / offline".
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    AuthService.instance.profile().then((p) {
      if (mounted) setState(() => _username = (p['username'] as String?) ?? '');
    });
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DeviceStatus>(
      stream: _status,
      builder: (context, statusSnap) {
        final status = statusSnap.data ?? DeviceStatus.empty;
        return StreamBuilder<FeederConfig>(
          stream: _config,
          builder: (context, configSnap) {
            final config = configSnap.data ?? FeederConfig.defaults;
            _demoMode = config.demoMode;
            return StreamBuilder<List<Pet>>(
              stream: _pets,
              builder: (context, petSnap) {
                final pets = petSnap.data ?? const <Pet>[];
                return RefreshIndicator(
                  onRefresh: () async =>
                      Future<void>.delayed(const Duration(milliseconds: 400)),
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                    child: PageBody(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _header(status),
                          if (statusSnap.hasError)
                            _errorBanner(statusSnap.error.toString()),
                          const SectionHeader('Environment'),
                          _environment(status, config),
                          SectionHeader(
                            'Food compartments',
                            subtitle: 'Live bowl weight from the load cells',
                            trailing: TextButton(
                              onPressed: () => widget.onNavigate?.call(1),
                              child: const Text('Configure'),
                            ),
                          ),
                          _compartments(status, config, pets),
                          SectionHeader(
                            'Pet recognition',
                            subtitle: 'Last animal seen by the camera',
                            trailing: TextButton.icon(
                              onPressed: _openLiveView,
                              icon: const Icon(Icons.live_tv, size: 18),
                              label: const Text('Live view'),
                            ),
                          ),
                          _detectionCard(status.lastDetection),
                          const SectionHeader('Quick actions'),
                          _quickActions(status, config, pets),
                          const SectionHeader('Recent activity'),
                          _recentActivity(),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _openLiveView() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const LiveViewPage()));

  // ------------------------------------------------------------------ header

  Widget _header(DeviceStatus s) {
    final theme = Theme.of(context);
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _username.isEmpty ? '$greeting!' : '$greeting, $_username!',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusPill(
                label: s.feederOnline ? 'Feeder online' : 'Feeder offline',
                ok: s.feederOnline,
                icon: Icons.memory,
              ),
              if (_demoMode)
                const StatusPill(
                  label: 'Demo mode ON',
                  ok: false,
                  icon: Icons.slideshow,
                ),
              StatusPill(
                label: s.cameraLabel,
                ok: s.cameraOnline && s.cameraMode != 'off',
                icon: Icons.photo_camera_outlined,
              ),
              if (s.espLastSeen != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Updated ${timeAgo(s.espLastSeen)}',
                      style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String error) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          color: AppTheme.danger.withValues(alpha: 0.1),
          child: ListTile(
            leading: const Icon(Icons.error_outline, color: AppTheme.danger),
            title: const Text('Cannot read the database'),
            subtitle: Text(error, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        ),
      );

  // ------------------------------------------------------------- environment

  Widget _environment(DeviceStatus s, FeederConfig c) {
    final t = s.temperature;
    final hot = t != null && t >= c.tempThreshold;
    return ResponsiveGrid(
      children: [
        StatCard(
          icon: Icons.thermostat,
          color: hot ? AppTheme.danger : AppTheme.temp,
          title: 'Temperature',
          value: t == null ? '--' : '${t.toStringAsFixed(1)} °C',
          caption: hot
              ? 'Above ${c.tempThreshold.toStringAsFixed(0)} °C limit'
              : 'Limit ${c.tempThreshold.toStringAsFixed(0)} °C',
        ),
        StatCard(
          icon: Icons.water,
          color: Colors.indigo,
          title: 'Humidity',
          value: s.humidity == null ? '--' : '${s.humidity!.toStringAsFixed(0)} %',
          caption: 'DHT22 sensor',
        ),
        StatCard(
          icon: Icons.air,
          color: AppTheme.fan,
          title: 'Cooling fan',
          value: s.fanOn ? 'ON' : 'OFF',
          caption: s.fanRunningFor == null
              ? 'Mode: ${c.fanMode.toUpperCase()}'
              : '${c.fanMode.toUpperCase()} · on for ${s.fanRunningFor}',
          onTap: () => widget.onNavigate?.call(1),
        ),
        StatCard(
          icon: Icons.water_drop,
          color: s.waterLow ? AppTheme.warn : AppTheme.water,
          title: 'Water bowl',
          value: s.waterPct == null ? '--' : '${s.waterPct!.toStringAsFixed(0)} %',
          caption: s.reservoirEmpty
              ? 'Reservoir empty - refill!'
              : s.pumpOn
                  ? 'Pump running...'
                  : (s.waterLow ? 'Low - refilling soon' : 'OK'),
          footer: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ((s.waterPct ?? 0) / 100).clamp(0.0, 1.0),
              minHeight: 6,
              color: AppTheme.water,
              backgroundColor: AppTheme.water.withValues(alpha: 0.15),
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ compartments

  Widget _compartments(DeviceStatus s, FeederConfig c, List<Pet> pets) {
    final theme = Theme.of(context);
    return ResponsiveGrid(
      minItemWidth: 300,
      children: [
        for (final id in AppConfig.compartments)
          Builder(builder: (context) {
            final comp = c.compartments[id]!;
            final petsHere = comp.species == null
                ? const <Pet>[]
                : pets.where((p) => p.species == comp.species && p.enabled).toList();
            final weight = s.bowlGrams[id];
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: AppTheme.food.withValues(alpha: 0.14),
                          child: Text(Species.emoji(comp.species),
                              style: const TextStyle(fontSize: 22)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Compartment $id',
                                  style: theme.textTheme.labelMedium),
                              Text(comp.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w800)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(grams(weight),
                                style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.food)),
                            Text('in bowl', style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (comp.species == null)
                      Text('No food type assigned yet.',
                          style: theme.textTheme.bodyMedium)
                    else if (petsHere.isEmpty)
                      Text('No ${comp.species!.toLowerCase()} profile yet - add one in Pets.',
                          style: theme.textTheme.bodyMedium)
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final p in petsHere)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: Text(Species.emoji(p.species)),
                              label: Text(
                                  '${p.name} · ${p.portionG.toStringAsFixed(0)} g'),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  // --------------------------------------------------------------- detection

  Widget _detectionCard(Detection? d) {
    final theme = Theme.of(context);
    if (d == null) {
      return const Card(
        child: EmptyState(
          icon: Icons.photo_camera_outlined,
          title: 'No detections yet',
          message:
              'When a pet walks up to the feeder, the camera identifies it and the result appears here.',
        ),
      );
    }

    Uint8List? image;
    if (d.imageBase64 != null && d.imageBase64!.isNotEmpty) {
      try {
        image = base64Decode(d.imageBase64!);
      } catch (_) {}
    }

    final color = d.decision == 'dispensed'
        ? AppTheme.ok
        : d.decision == 'denied'
            ? AppTheme.warn
            : Colors.blueGrey;

    final info = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(Species.emoji(d.species), style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(ModelClasses.pretty(d.label),
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${d.species} · ${(d.confidence * 100).toStringAsFixed(0)}% confidence',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              d.message.isEmpty ? d.decision : d.message,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          Text(formatDateTime(d.time), style: theme.textTheme.bodySmall),
        ],
      ),
    );

    final picture = Container(
      color: Colors.black,
      child: image == null
          ? const Center(
              child: Icon(Icons.image_not_supported_outlined,
                  color: Colors.white38, size: 40))
          : Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return SizedBox(
            height: 200,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 260, child: picture),
                Expanded(child: info),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(aspectRatio: 4 / 3, child: picture),
            info,
          ],
        );
      }),
    );
  }

  // ----------------------------------------------------------- quick actions

  Widget _quickActions(DeviceStatus s, FeederConfig c, List<Pet> pets) {
    final offline = !s.feederOnline || !s.cameraOnline;
    final actions = <Widget>[
      for (final id in AppConfig.compartments)
        _ActionTile(
          icon: Icons.restaurant,
          color: AppTheme.food,
          label: 'Feed $id',
          sub: c.compartments[id]!.displayName,
          onTap: () => showFeedDialog(context, compartment: id, config: c, pets: pets),
        ),
      _ActionTile(
        icon: Icons.water_drop,
        color: AppTheme.water,
        label: 'Add water',
        sub: 'Fill to full',
        onTap: () => runWithFeedback(context, () => _feeder.fillWater(),
            success: 'Filling the bowl to full'),
      ),
      _ActionTile(
        icon: Icons.air,
        color: AppTheme.fan,
        label: s.fanOn ? 'Fan off' : 'Fan on',
        sub: 'Manual override',
        onTap: () => runWithFeedback(
          context,
          () => _feeder.setFanMode(s.fanOn ? 'off' : 'on'),
          success: 'Fan set to ${s.fanOn ? 'OFF' : 'ON'} (set back to AUTO in Feeder tab)',
        ),
      ),
      _ActionTile(
        icon: Icons.live_tv,
        color: Colors.redAccent,
        label: 'Live view',
        sub: c.cameraMode == 'off' ? 'Camera is off' : 'See the camera now',
        onTap: _openLiveView,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (offline)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Commands are queued and will run when the feeder and camera are online.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ResponsiveGrid(minItemWidth: 150, children: actions),
      ],
    );
  }

  // --------------------------------------------------------- recent activity

  Widget _recentActivity() {
    return StreamBuilder<List<LogEntry>>(
      stream: _logs,
      builder: (context, snap) {
        // Only owner-relevant events; the full log is on the History page.
        final logs = (snap.data ?? const <LogEntry>[])
            .where((l) => l.isImportant)
            .take(8)
            .toList();
        if (logs.isEmpty) {
          return const Card(
            child: EmptyState(
              icon: Icons.history,
              title: 'No activity yet',
              message: 'Feeding, water and fan events will show up here.',
            ),
          );
        }
        return Card(
          child: Column(
            children: [
              for (var i = 0; i < logs.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 64),
                _LogTile(entry: logs[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String sub;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          child: Column(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color.withValues(alpha: 0.14),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 10),
              Text(label,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final LogEntry entry;
  const _LogTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final style = iconForType(entry.type, level: entry.level);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: style.color.withValues(alpha: 0.12),
        child: Icon(style.icon, color: style.color, size: 20),
      ),
      title: Text(entry.message,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(timeAgo(entry.time)),
    );
  }
}
