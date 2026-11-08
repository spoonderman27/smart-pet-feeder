import 'dart:async';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/feeder_models.dart';
import '../models/pet.dart';
import '../services/feeder_service.dart';
import '../services/pet_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'feed_dialog.dart';
import 'live_view_page.dart';

/// Remote hardware controller + feeder settings.
class FeederControlPage extends StatefulWidget {
  const FeederControlPage({super.key});

  @override
  State<FeederControlPage> createState() => _FeederControlPageState();
}

class _FeederControlPageState extends State<FeederControlPage> {
  final _feeder = FeederService.instance;
  late final Stream<FeederConfig> _config = _feeder.configStream();
  late final Stream<DeviceStatus> _status = _feeder.statusStream();
  late final Stream<List<Pet>> _pets = PetRepository.instance.petsStream();

  // Redraw every 10 s so "online / offline" updates even when no new data arrives.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
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
    return StreamBuilder<FeederConfig>(
      stream: _config,
      builder: (context, configSnap) {
        final config = configSnap.data ?? FeederConfig.defaults;
        return StreamBuilder<DeviceStatus>(
          stream: _status,
          builder: (context, statusSnap) {
            final status = statusSnap.data ?? DeviceStatus.empty;
            return StreamBuilder<List<Pet>>(
              stream: _pets,
              builder: (context, petSnap) {
                final pets = petSnap.data ?? const <Pet>[];
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: PageBody(
                    maxWidth: 900,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeader('Food compartments',
                            subtitle:
                                'Tell the feeder which food is loaded in each hopper. '
                                'Detected pets only get food from the compartment of their species.'),
                        for (final id in AppConfig.compartments) ...[
                          _CompartmentEditor(
                            key: ValueKey('comp-$id-${config.compartments[id]!.species}'),
                            comp: config.compartments[id]!,
                            other: config.compartments.values
                                .firstWhere((c) => c.id != id),
                            bowlGrams: status.bowlGrams[id],
                            onFeed: () => showFeedDialog(context,
                                compartment: id, config: config, pets: pets),
                          ),
                          const SizedBox(height: 12),
                        ],
                        const SectionHeader('Cooling fan',
                            subtitle: 'AUTO turns the fan on above the temperature limit'),
                        _climateCard(config, status),
                        const SectionHeader('Water dispenser'),
                        _waterCard(config, status),
                        const SectionHeader('Camera',
                            subtitle: 'AUTO lets the camera rest and wakes it when something comes near'),
                        _cameraCard(config, status),
                        const SectionHeader('Pet recognition',
                            subtitle: 'How the ultrasonic sensor and camera decide a pet is there'),
                        _recognitionCard(config),
                        const SectionHeader('Device'),
                        _deviceCard(status),
                      ],
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

  Widget _climateCard(FeederConfig c, DeviceStatus s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.air, color: s.fanOn ? AppTheme.fan : Colors.grey),
                const SizedBox(width: 8),
                Text(
                    !s.feederOnline
                        ? 'Feeder offline'
                        : !s.fanOn
                            ? 'Fan is off'
                            : s.fanRunningFor == null
                                ? 'Fan is running'
                                : 'Fan is running (${s.fanRunningFor})',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(s.temperature == null
                    ? '-- °C'
                    : '${s.temperature!.toStringAsFixed(1)} °C'),
              ],
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto'), icon: Icon(Icons.auto_mode)),
                ButtonSegment(value: 'on', label: Text('On'), icon: Icon(Icons.toggle_on)),
                ButtonSegment(value: 'off', label: Text('Off'), icon: Icon(Icons.toggle_off)),
              ],
              selected: {c.fanMode},
              onSelectionChanged: (sel) => runWithFeedback(
                context,
                () => _feeder.setFanMode(sel.first),
                success: 'Fan mode: ${sel.first.toUpperCase()}',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              switch (c.fanMode) {
                'on' => 'Fan always on.',
                'off' => 'Fan always off.',
                _ => 'Turns on at ${c.tempThreshold.toStringAsFixed(1)} °C and off again at '
                    '${(c.tempThreshold - 1).toStringAsFixed(1)} °C.',
              },
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _ConfigSlider(
              key: ValueKey('thr-${c.tempThreshold}'),
              label: 'Temperature limit',
              value: c.tempThreshold,
              min: 24,
              max: 38,
              divisions: 28,
              format: (v) => '${v.toStringAsFixed(1)} °C',
              onCommit: (v) => _feeder.updateConfig({'tempThreshold': v}),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waterCard(FeederConfig c, DeviceStatus s) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.opacity, color: AppTheme.water),
            title: Text(s.waterPct == null
                ? 'Water level: --'
                : 'Water level: ${s.waterPct!.toStringAsFixed(0)} %'),
            subtitle: Text(s.reservoirEmpty
                ? 'Reservoir looks empty - refill the tank'
                : (s.pumpOn ? 'Pump running' : 'Pump idle')),
            trailing: FilledButton.tonal(
              onPressed: () => runWithFeedback(
                context,
                () => _feeder.fillWater(),
                success: 'Filling the bowl to full',
              ),
              child: const Text('Fill to full'),
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.water_drop, color: AppTheme.water),
            title: const Text('Refill when low'),
            subtitle: const Text('Water level sensor: pump starts below 30%'),
            value: c.waterAuto,
            onChanged: (v) => runWithFeedback(
              context,
              () => _feeder.updateConfig({'waterAuto': v}),
              success: v ? 'Refill when low: ON' : 'Refill when low: OFF',
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.sensors, color: AppTheme.water),
            title: const Text('Top up when a pet comes to drink'),
            subtitle: const Text(
                'Ultrasonic sensor: Pet detected and the level is below 65%'),
            value: c.petTopUp,
            onChanged: (v) => runWithFeedback(
              context,
              () => _feeder.updateConfig({'petTopUp': v}),
              success: v ? 'Pet top-up: ON' : 'Pet top-up: OFF',
            ),
          ),
          const Divider(height: 1),
          ExpansionTile(
            leading: const Icon(Icons.tune),
            title: const Text('Calibrate water sensor'),
            subtitle: Text(
                'Sensor now: ${s.waterRaw ?? '--'} · saved empty ${s.waterCalEmpty ?? '--'}, '
                'full ${s.waterCalFull ?? '--'}'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '1. Turn both switches above OFF so the pump does not start.\n'
                '2. Empty the bowl, wait 5 s, tap "Save EMPTY".\n'
                '3. Fill the bowl by hand to the level you call full, wait 5 s, tap "Save FULL".\n'
                '4. Turn the switches back ON.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => runWithFeedback(
                        context,
                        () => _feeder.calibrateWater('empty'),
                        success: 'EMPTY point sent - check Recent activity',
                      ),
                      child: const Text('Save EMPTY'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => runWithFeedback(
                        context,
                        () => _feeder.calibrateWater('full'),
                        success: 'FULL point sent - check Recent activity',
                      ),
                      child: const Text('Save FULL'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cameraCard(FeederConfig c, DeviceStatus s) {
    final explain = switch (c.cameraMode) {
      'on' => 'Camera always on. The LCD always shows the live picture.',
      'off' => 'Camera off. Pets are NOT fed automatically and there is no live view.',
      _ => 'Camera rests and wakes up when something moves closer than '
          '${c.wakeCm} cm, when a pet reaches the bowl, or when you open Live view.',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  c.cameraMode == 'off' ? Icons.videocam_off : Icons.videocam,
                  color: s.cameraOn ? AppTheme.ok : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(s.cameraLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto'), icon: Icon(Icons.auto_mode)),
                ButtonSegment(value: 'on', label: Text('On'), icon: Icon(Icons.videocam)),
                ButtonSegment(value: 'off', label: Text('Off'), icon: Icon(Icons.videocam_off)),
              ],
              selected: {c.cameraMode},
              onSelectionChanged: (sel) => runWithFeedback(
                context,
                () => _feeder.setCameraMode(sel.first),
                success: 'Camera mode: ${sel.first.toUpperCase()}',
              ),
            ),
            const SizedBox(height: 10),
            Text(explain, style: Theme.of(context).textTheme.bodySmall),
            if (c.cameraMode == 'auto') ...[
              const SizedBox(height: 8),
              _ConfigSlider(
                key: ValueKey('wake-${c.wakeCm}'),
                label: 'Wake camera when closer than',
                value: c.wakeCm.toDouble().clamp(20.0, 80.0),
                min: 20,
                max: 80,
                divisions: 12,
                format: (v) => '${v.toStringAsFixed(0)} cm',
                onCommit: (v) => _feeder.updateConfig({'wakeCm': v.round()}),
              ),
              Text(
                'Always at least 5 cm more than the pet detection distance '
                '(${c.presenceCm} cm), so the camera is ready in time.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: c.cameraMode == 'off'
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const LiveViewPage())),
              icon: const Icon(Icons.live_tv),
              label: const Text('Open live view'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recognitionCard(FeederConfig c) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ConfigSlider(
              key: ValueKey('pres-${c.presenceCm}'),
              label: 'Pet detected when closer than',
              value: c.presenceCm.toDouble(),
              min: 10,
              max: 60,
              divisions: 10,
              format: (v) => '${v.toStringAsFixed(0)} cm',
              onCommit: (v) => _feeder.updateConfig({'presenceCm': v.round()}),
            ),
            const SizedBox(height: 8),
            _ConfigSlider(
              key: ValueKey('conf-${c.minConfidence}'),
              label: 'Minimum AI confidence',
              value: c.minConfidence,
              min: 0.3,
              max: 0.9,
              divisions: 12,
              format: (v) => '${(v * 100).toStringAsFixed(0)} %',
              onCommit: (v) => _feeder.updateConfig(
                  {'minConfidence': double.parse(v.toStringAsFixed(2))}),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(Icons.slideshow,
                  color: c.demoMode ? Colors.orange : Colors.grey),
              title: const Text('Demo mode'),
              subtitle: const Text(
                  'Ignore the meals limit and the time between meals'),
              value: c.demoMode,
              onChanged: (v) => runWithFeedback(
                context,
                () => _feeder.updateConfig({'demoMode': v}),
                success: v ? 'Demo mode ON - meal limits ignored' : 'Demo mode OFF',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => runWithFeedback(
                context,
                () => _feeder.testIdentify(),
                success: 'Camera check requested - see Dashboard',
              ),
              icon: const Icon(Icons.center_focus_strong),
              label: const Text('Run camera check'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(DeviceStatus s) {
    String signal(int? rssi) {
      if (rssi == null) return '--';
      final q = rssi > -55
          ? 'Excellent'
          : rssi > -67
              ? 'Good'
              : rssi > -75
                  ? 'Fair'
                  : 'Weak';
      return '$rssi dBm ($q)';
    }

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.memory,
                color: s.feederOnline ? AppTheme.ok : AppTheme.danger),
            title: Text('ESP32 feeder - ${s.feederOnline ? 'online' : 'offline'}'),
            subtitle: Text('Last data ${timeAgo(s.espLastSeen)} · Wi-Fi ${signal(s.rssi)}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.photo_camera,
                color: s.cameraOnline ? AppTheme.ok : AppTheme.danger),
            title: Text('Raspberry Pi camera - ${s.cameraOnline ? 'online' : 'offline'}'),
            subtitle: Text('Last heartbeat ${timeAgo(s.piLastSeen)} · ${s.cameraLabel}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Re-sync pet profiles to feeder'),
            subtitle: const Text('Use if the Pi does not recognise a saved pet'),
            onTap: () async {
              try {
                final n = await PetRepository.instance.resyncAll();
                if (mounted) showSnack(context, 'Synced $n pet profile(s)');
              } catch (e) {
                if (mounted) showSnack(context, 'Failed: $e', error: true);
              }
            },
          ),
        ],
      ),
    );
  }
}

/// One compartment: food type, label, live weight, tare, feed.
class _CompartmentEditor extends StatefulWidget {
  final CompartmentConfig comp;
  final CompartmentConfig other;
  final double? bowlGrams;
  final VoidCallback onFeed;

  const _CompartmentEditor({
    super.key,
    required this.comp,
    required this.other,
    required this.bowlGrams,
    required this.onFeed,
  });

  @override
  State<_CompartmentEditor> createState() => _CompartmentEditorState();
}

class _CompartmentEditorState extends State<_CompartmentEditor> {
  late final _labelController = TextEditingController(text: widget.comp.label);
  late String? _species = widget.comp.species;
  bool _saving = false;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _species != widget.comp.species ||
      _labelController.text.trim() != widget.comp.label;

  Future<void> _save() async {
    if (_species != null && _species == widget.other.species) {
      showSnack(context,
          'Compartment ${widget.other.id} already holds $_species food. '
          'Each species can only use one compartment.',
          error: true);
      return;
    }
    setState(() => _saving = true);
    await runWithFeedback(
      context,
      () => FeederService.instance.setCompartment(CompartmentConfig(
        id: widget.comp.id,
        species: _species,
        label: _labelController.text.trim(),
      )),
      success: 'Compartment ${widget.comp.id} saved',
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppTheme.food.withValues(alpha: 0.14),
                  child: Text(widget.comp.id,
                      style: const TextStyle(
                          fontWeight: FontWeight.w900, color: AppTheme.food)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Compartment ${widget.comp.id}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                Text(grams(widget.bowlGrams, digits: 1),
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: AppTheme.food, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in [...Species.all, 'None'])
                  ChoiceChip(
                    avatar: s == 'None' ? null : Text(Species.emoji(s)),
                    label: Text(s == 'None' ? 'Empty' : s),
                    selected: (_species ?? 'None') == s,
                    onSelected: (_) =>
                        setState(() => _species = s == 'None' ? null : s),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Food name (optional)',
                hintText: 'e.g. Whiskas Adult Tuna',
                prefixIcon: Icon(Icons.label_outline),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () => runWithFeedback(
                    context,
                    () => FeederService.instance.tare(widget.comp.id),
                    success: 'Tare sent - keep bowl ${widget.comp.id} empty',
                  ),
                  icon: const Icon(Icons.exposure_zero),
                  label: const Text('Tare bowl'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onFeed,
                  icon: const Icon(Icons.restaurant),
                  label: const Text('Feed now'),
                ),
                FilledButton.icon(
                  onPressed: (_dirty && !_saving) ? _save : null,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Slider that only writes to the database when the user lets go.
class _ConfigSlider extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final Future<void> Function(double) onCommit;

  const _ConfigSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onCommit,
  });

  @override
  State<_ConfigSlider> createState() => _ConfigSliderState();
}

class _ConfigSliderState extends State<_ConfigSlider> {
  late double _value = widget.value.clamp(widget.min, widget.max);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label)),
            Text(widget.format(_value),
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        Slider(
          value: _value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: widget.format(_value),
          onChanged: (v) => setState(() => _value = v),
          onChangeEnd: (v) => runWithFeedback(context, () => widget.onCommit(v),
              success: '${widget.label}: ${widget.format(v)}'),
        ),
      ],
    );
  }
}
