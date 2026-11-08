import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../models/feeder_models.dart';
import '../services/feeder_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Data dashboard: temperature graph, food consumption chart, event logs.
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 3,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(icon: Icon(Icons.thermostat), text: 'Environment'),
              Tab(icon: Icon(Icons.restaurant), text: 'Feeding'),
              Tab(icon: Icon(Icons.list_alt), text: 'Logs'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [_EnvironmentTab(), _FeedingTab(), _LogsTab()],
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Environment
// ===========================================================================

class _EnvironmentTab extends StatefulWidget {
  const _EnvironmentTab();

  @override
  State<_EnvironmentTab> createState() => _EnvironmentTabState();
}

class _EnvironmentTabState extends State<_EnvironmentTab>
    with AutomaticKeepAliveClientMixin {
  Duration _range = const Duration(hours: 24);
  late Stream<List<EnvPoint>> _stream = _makeStream();

  Stream<List<EnvPoint>> _makeStream() => FeederService.instance
      .envHistoryStream(since: DateTime.now().subtract(_range));

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 6, label: Text('6 h')),
                    ButtonSegment(value: 24, label: Text('24 h')),
                    ButtonSegment(value: 168, label: Text('7 days')),
                  ],
                  selected: {_range.inHours},
                  onSelectionChanged: (sel) => setState(() {
                    _range = Duration(hours: sel.first);
                    _stream = _makeStream();
                  }),
                ),
              ),
              const SizedBox(height: 12),
              StreamBuilder<List<EnvPoint>>(
                stream: _stream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Card(
                        child: EmptyState(
                            icon: Icons.error_outline,
                            title: 'Could not load history',
                            message: snap.error.toString()));
                  }
                  final points = snap.data ?? const <EnvPoint>[];
                  if (points.length < 2) {
                    return const Card(
                      child: EmptyState(
                        icon: Icons.show_chart,
                        title: 'Not enough data yet',
                        message:
                            'The Raspberry Pi saves a temperature reading every 5 minutes.',
                      ),
                    );
                  }
                  final temps = points.where((p) => p.temperature != null).toList();
                  final hums = points.where((p) => p.humidity != null).toList();
                  double avg(List<double> v) =>
                      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
                  final tVals = temps.map((p) => p.temperature!).toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (tVals.isNotEmpty)
                        ResponsiveGrid(children: [
                          StatCard(
                              icon: Icons.arrow_downward,
                              color: AppTheme.water,
                              title: 'Min',
                              value: '${tVals.reduce((a, b) => math.min(a, b)).toStringAsFixed(1)} °C'),
                          StatCard(
                              icon: Icons.functions,
                              color: AppTheme.ok,
                              title: 'Average',
                              value: '${avg(tVals).toStringAsFixed(1)} °C'),
                          StatCard(
                              icon: Icons.arrow_upward,
                              color: AppTheme.danger,
                              title: 'Max',
                              value: '${tVals.reduce((a, b) => math.max(a, b)).toStringAsFixed(1)} °C'),
                        ]),
                      const SectionHeader('Temperature (°C)'),
                      _ChartCard(
                        child: _TimeLineChart(
                          points: [
                            for (final p in temps) (p.time, p.temperature!),
                          ],
                          color: AppTheme.temp,
                          range: _range,
                        ),
                      ),
                      const SectionHeader('Humidity (%)'),
                      _ChartCard(
                        child: _TimeLineChart(
                          points: [
                            for (final p in hums) (p.time, p.humidity!),
                          ],
                          color: Colors.indigo,
                          range: _range,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  final Widget child;
  const _ChartCard({required this.child});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 20, 8),
          child: SizedBox(height: 220, child: child),
        ),
      );
}

class _TimeLineChart extends StatelessWidget {
  final List<(DateTime, double)> points;
  final Color color;
  final Duration range;

  const _TimeLineChart({
    required this.points,
    required this.color,
    required this.range,
  });

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return const Center(child: Text('No data'));
    }
    final theme = Theme.of(context);
    final faded = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final spots = [
      for (final p in points)
        FlSpot(p.$1.millisecondsSinceEpoch.toDouble(), p.$2),
    ];
    final minX = spots.first.x;
    final maxX = spots.last.x;
    final ys = spots.map((s) => s.y);
    final minY = (ys.reduce((a, b) => math.min(a, b)) - 2).floorToDouble();
    final maxY = (ys.reduce((a, b) => math.max(a, b)) + 2).ceilToDouble();
    final xInterval = math.max((maxX - minX) / 4, 60000.0);
    final fmt = range.inHours > 24 ? DateFormat('d/M') : DateFormat('HH:mm');

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        borderData: FlBorderData(show: false),
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: math.max((maxY - minY) / 4, 1),
          getDrawingHorizontalLine: (_) =>
              FlLine(color: faded.withValues(alpha: 0.15), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: math.max((maxY - minY) / 4, 1),
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(0),
                style: TextStyle(fontSize: 11, color: faded),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: xInterval,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  fmt.format(DateTime.fromMillisecondsSinceEpoch(value.toInt())),
                  style: TextStyle(fontSize: 11, color: faded),
                ),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            color: color,
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Feeding
// ===========================================================================

class _FeedingTab extends StatefulWidget {
  const _FeedingTab();

  @override
  State<_FeedingTab> createState() => _FeedingTabState();
}

class _FeedingTabState extends State<_FeedingTab>
    with AutomaticKeepAliveClientMixin {
  late final DateTime _start = DateUtils.dateOnly(DateTime.now())
      .subtract(const Duration(days: 6));
  late final Stream<List<FeedingRecord>> _stream =
      FeederService.instance.feedingsStream(since: _start);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return StreamBuilder<List<FeedingRecord>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
              child: EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not load feedings',
                  message: snap.error.toString()));
        }
        final records = snap.data ?? const <FeedingRecord>[];

        // grams per day per compartment
        final days = [for (var i = 0; i < 7; i++) _start.add(Duration(days: i))];
        final totals = {
          for (final c in AppConfig.compartments) c: List<double>.filled(7, 0),
        };
        for (final r in records.where((r) => r.ok && r.time != null)) {
          final idx = DateUtils.dateOnly(r.time!).difference(_start).inDays;
          if (idx < 0 || idx > 6) continue;
          final list = totals[r.compartment];
          if (list != null) list[idx] += r.dispensedG;
        }
        final maxVal = totals.values.expand((e) => e).fold<double>(0, (a, b) => math.max(a, b));

        final today = records.where((r) =>
            r.ok && r.time != null && DateUtils.isSameDay(r.time!, DateTime.now()));
        final gramsToday = today.fold<double>(0, (a, r) => a + r.dispensedG);
        final eatenToday = today.fold<double>(0, (a, r) => a + (r.eatenG ?? 0));
        final denied = records.where((r) => !r.ok).length;

        const colors = {'A': AppTheme.food, 'B': AppTheme.accentColor};

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ResponsiveGrid(children: [
                    StatCard(
                      icon: Icons.restaurant,
                      color: AppTheme.food,
                      title: 'Meals today',
                      value: '${today.length}',
                    ),
                    StatCard(
                      icon: Icons.scale,
                      color: AppTheme.ok,
                      title: 'Dispensed today',
                      value: '${gramsToday.toStringAsFixed(0)} g',
                    ),
                    StatCard(
                      icon: Icons.pets,
                      color: Colors.deepPurple,
                      title: 'Eaten today',
                      value: '${eatenToday.toStringAsFixed(0)} g',
                      caption: 'Measured by bowl weight drop',
                    ),
                    StatCard(
                      icon: Icons.block,
                      color: AppTheme.warn,
                      title: 'Refused (7 d)',
                      value: '$denied',
                      caption: 'Wrong pet / limit reached',
                    ),
                  ]),
                  const SectionHeader('Food dispensed per day (g)'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 20, 16, 8),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 220,
                            child: BarChart(
                              BarChartData(
                                maxY: maxVal <= 0 ? 50 : maxVal * 1.2,
                                borderData: FlBorderData(show: false),
                                gridData: const FlGridData(drawVerticalLine: false),
                                titlesData: FlTitlesData(
                                  topTitles: const AxisTitles(),
                                  rightTitles: const AxisTitles(),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 36,
                                      getTitlesWidget: (v, meta) => Text(
                                          v.toStringAsFixed(0),
                                          style: const TextStyle(fontSize: 11)),
                                    ),
                                  ),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 26,
                                      getTitlesWidget: (v, meta) {
                                        final i = v.toInt();
                                        if (i < 0 || i > 6) return const SizedBox();
                                        return Padding(
                                          padding: const EdgeInsets.only(top: 6),
                                          child: Text(
                                              DateFormat('E').format(days[i]),
                                              style: const TextStyle(fontSize: 11)),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                barGroups: [
                                  for (var i = 0; i < 7; i++)
                                    BarChartGroupData(
                                      x: i,
                                      barsSpace: 4,
                                      barRods: [
                                        for (final c in AppConfig.compartments)
                                          BarChartRodData(
                                            toY: totals[c]![i],
                                            width: 10,
                                            color: colors[c],
                                            borderRadius: const BorderRadius.vertical(
                                                top: Radius.circular(4)),
                                          ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 16,
                            children: [
                              for (final c in AppConfig.compartments)
                                Row(mainAxisSize: MainAxisSize.min, children: [
                                  Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                          color: colors[c],
                                          borderRadius: BorderRadius.circular(3))),
                                  const SizedBox(width: 6),
                                  Text('Compartment $c',
                                      style: theme.textTheme.bodySmall),
                                ]),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SectionHeader('Feeding log (last 7 days)'),
                  if (records.isEmpty)
                    const Card(
                      child: EmptyState(
                          icon: Icons.restaurant_menu,
                          title: 'No feedings recorded yet'),
                    )
                  else
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < records.length && i < 50; i++) ...[
                            if (i > 0) const Divider(height: 1, indent: 64),
                            _FeedingTile(r: records[i]),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FeedingTile extends StatelessWidget {
  final FeedingRecord r;
  const _FeedingTile({required this.r});

  @override
  Widget build(BuildContext context) {
    final color = r.ok ? AppTheme.food : AppTheme.warn;
    final eaten = r.eatenG == null ? '' : ' · ate ${r.eatenG!.toStringAsFixed(0)} g';
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.12),
        child: Text(Species.emoji(r.species)),
      ),
      title: Text(
        r.ok
            ? '${r.petName} · ${r.dispensedG.toStringAsFixed(0)} g from ${r.compartment}'
            : '${r.petName} · not fed',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        '${formatDateTime(r.time)} · ${r.source}'
        '${r.ok ? ' · target ${r.targetG.toStringAsFixed(0)} g$eaten' : ' · ${r.reason}'}',
      ),
      trailing: Icon(r.ok ? Icons.check_circle : Icons.block, color: color),
    );
  }
}

// ===========================================================================
// Logs
// ===========================================================================

class _LogsTab extends StatefulWidget {
  const _LogsTab();

  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> with AutomaticKeepAliveClientMixin {
  late final Stream<List<LogEntry>> _stream =
      FeederService.instance.logsStream(limit: 100);
  String _filter = 'all';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return StreamBuilder<List<LogEntry>>(
      stream: _stream,
      builder: (context, snap) {
        final all = snap.data ?? const <LogEntry>[];
        final logs =
            _filter == 'all' ? all : all.where((l) => l.type == _filter).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in const ['all', 'feed', 'detect', 'water', 'fan', 'system'])
                        ChoiceChip(
                          label: Text(f[0].toUpperCase() + f.substring(1)),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (logs.isEmpty)
                    const Card(
                        child: EmptyState(icon: Icons.list_alt, title: 'No log entries'))
                  else
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < logs.length; i++) ...[
                            if (i > 0) const Divider(height: 1, indent: 64),
                            Builder(builder: (context) {
                              final l = logs[i];
                              final s = iconForType(l.type, level: l.level);
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: s.color.withValues(alpha: 0.12),
                                  child: Icon(s.icon, color: s.color, size: 20),
                                ),
                                title: Text(l.message),
                                subtitle: Text(formatDateTime(l.time)),
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
