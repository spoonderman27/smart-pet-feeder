import 'package:flutter/material.dart';

import '../config.dart';
import '../models/feeder_models.dart';
import '../models/pet.dart';
import '../services/feeder_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Bottom sheet to dispense a manual portion from one compartment.
/// Manual feeding skips the camera check (owner override) but the ESP32 still
/// measures the bowl with the load cell, so the portion is accurate.
Future<void> showFeedDialog(
  BuildContext context, {
  required String compartment,
  required FeederConfig config,
  required List<Pet> pets,
}) {
  final comp = config.compartments[compartment]!;
  final matching = comp.species == null
      ? const <Pet>[]
      : pets.where((p) => p.species == comp.species).toList();
  final initial = matching.isNotEmpty ? matching.first.portionG : 30.0;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _FeedSheet(
      compartment: compartment,
      comp: comp,
      pets: matching,
      initialGrams: initial.clamp(5.0, 300.0),
    ),
  );
}

class _FeedSheet extends StatefulWidget {
  final String compartment;
  final CompartmentConfig comp;
  final List<Pet> pets;
  final double initialGrams;

  const _FeedSheet({
    required this.compartment,
    required this.comp,
    required this.pets,
    required this.initialGrams,
  });

  @override
  State<_FeedSheet> createState() => _FeedSheetState();
}

class _FeedSheetState extends State<_FeedSheet> {
  late double _grams = widget.initialGrams;
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await FeederService.instance.dispense(widget.compartment, _grams);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        content: Text(
            'Dispensing ${_grams.toStringAsFixed(0)} g from compartment ${widget.compartment}'),
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showSnack(context, 'Failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Feed from compartment ${widget.compartment}',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '${Species.emoji(widget.comp.species)}  ${widget.comp.displayName}',
            style: theme.textTheme.bodyMedium,
          ),
          if (widget.comp.species == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Tip: assign a food type to this compartment in the Feeder tab.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warn),
              ),
            ),
          const SizedBox(height: 20),
          if (widget.pets.isNotEmpty) ...[
            Text('Use a saved portion', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in widget.pets)
                  ChoiceChip(
                    label: Text('${p.name} · ${p.portionG.toStringAsFixed(0)} g'),
                    selected: (_grams - p.portionG).abs() < 0.5,
                    onSelected: (_) =>
                        setState(() => _grams = p.portionG.clamp(5.0, 300.0)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              Text('Amount', style: theme.textTheme.labelLarge),
              const Spacer(),
              Text('${_grams.toStringAsFixed(0)} g',
                  style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800, color: AppTheme.food)),
            ],
          ),
          Slider(
            value: _grams,
            min: 5,
            max: 300,
            divisions: 59,
            label: '${_grams.toStringAsFixed(0)} g',
            onChanged: (v) => setState(() => _grams = v),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.restaurant),
            label: const Text('Dispense now'),
          ),
        ],
      ),
    );
  }
}
