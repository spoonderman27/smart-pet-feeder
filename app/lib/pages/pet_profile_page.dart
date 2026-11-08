import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import '../models/feeder_models.dart';
import '../models/pet.dart';
import '../services/feeder_service.dart';
import '../services/pet_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// List of the user's pets with today's feeding stats.
class PetProfilePage extends StatefulWidget {
  const PetProfilePage({super.key});

  @override
  State<PetProfilePage> createState() => _PetProfilePageState();
}

class _PetProfilePageState extends State<PetProfilePage> {
  late final Stream<List<Pet>> _pets = PetRepository.instance.petsStream();
  late final Stream<Map<String, PetStats>> _stats =
      FeederService.instance.petStatsStream();
  late final Stream<FeederConfig> _config = FeederService.instance.configStream();

  void _openForm([Pet? pet]) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PetFormPage(pet: pet)),
    );
  }

  Future<void> _delete(Pet pet) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${pet.name}?'),
        content: const Text(
            'The feeder will stop recognising this pet. Feeding history is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await runWithFeedback(context, () => PetRepository.instance.delete(pet.id),
        success: '${pet.name} deleted');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-pet',
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add pet'),
      ),
      body: StreamBuilder<List<Pet>>(
        stream: _pets,
        builder: (context, petSnap) {
          if (petSnap.hasError) {
            return Center(
                child: EmptyState(
                    icon: Icons.error_outline,
                    title: 'Could not load pets',
                    message: petSnap.error.toString()));
          }
          if (!petSnap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final pets = petSnap.data!;
          if (pets.isEmpty) {
            return Center(
              child: EmptyState(
                icon: Icons.pets,
                title: 'No pets yet',
                message:
                    'Add a profile for each pet so the feeder knows its breed and portion.',
                action: FilledButton.icon(
                  onPressed: () => _openForm(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add your first pet'),
                ),
              ),
            );
          }
          return StreamBuilder<FeederConfig>(
            stream: _config,
            builder: (context, configSnap) {
              final config = configSnap.data ?? FeederConfig.defaults;
              return StreamBuilder<Map<String, PetStats>>(
                stream: _stats,
                builder: (context, statSnap) {
                  final stats = statSnap.data ?? const <String, PetStats>{};
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    children: [
                      PageBody(
                        maxWidth: 900,
                        child: Column(
                          children: [
                            for (final pet in pets)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _PetCard(
                                  pet: pet,
                                  stats: stats[pet.id] ?? const PetStats(),
                                  compartment: config.compartmentFor(pet.species),
                                  onEdit: () => _openForm(pet),
                                  onDelete: () => _delete(pet),
                                  onToggle: (v) => runWithFeedback(
                                    context,
                                    () => PetRepository.instance.setEnabled(pet, v),
                                    success: v
                                        ? '${pet.name} will be fed automatically'
                                        : 'Automatic feeding paused for ${pet.name}',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _PetCard extends StatelessWidget {
  final Pet pet;
  final PetStats stats;
  final String? compartment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _PetCard({
    required this.pet,
    required this.stats,
    required this.compartment,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ImageProvider? image;
    if (pet.imageBase64 != null && pet.imageBase64!.isNotEmpty) {
      try {
        image = MemoryImage(base64Decode(pet.imageBase64!));
      } catch (_) {}
    }
    final mealsLeft = (pet.mealsPerDay - stats.mealsToday).clamp(0, 99);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.14),
                    backgroundImage: image,
                    child: image == null
                        ? Text(Species.emoji(pet.species),
                            style: const TextStyle(fontSize: 28))
                        : null,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pet.name,
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        Text(
                          '${pet.species} · ${ModelClasses.pretty(pet.breed)}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  Switch(value: pet.enabled, onChanged: onToggle),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') {
                        onEdit();
                      } else if (v == 'reset') {
                        runWithFeedback(
                          context,
                          () => FeederService.instance.resetPetStats(pet.id),
                          success: "${pet.name}: today's meals reset to 0",
                        );
                      } else {
                        onDelete();
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'reset', child: Text("Reset today's meals")),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InfoChip(
                    icon: Icons.restaurant,
                    text: '${pet.portionG.toStringAsFixed(0)} g × ${pet.mealsPerDay}/day',
                  ),
                  _InfoChip(
                    icon: Icons.today,
                    text: 'Today: ${stats.mealsToday} meal(s), '
                        '${stats.gramsToday.toStringAsFixed(0)} g',
                  ),
                  _InfoChip(
                    icon: Icons.schedule,
                    text: 'Last fed ${timeAgo(stats.lastFedAt)}',
                  ),
                  _InfoChip(
                    icon: Icons.inventory_2_outlined,
                    text: compartment == null
                        ? 'No ${pet.species.toLowerCase()} compartment!'
                        : 'Compartment $compartment',
                    color: compartment == null ? AppTheme.danger : null,
                  ),
                ],
              ),
              if (pet.enabled && compartment != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    mealsLeft == 0
                        ? 'Daily meals finished - the feeder will not dispense again today.'
                        : '$mealsLeft meal(s) left today.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _InfoChip({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12.5, color: c, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ===========================================================================
// Add / edit form
// ===========================================================================

class PetFormPage extends StatefulWidget {
  final Pet? pet;
  const PetFormPage({super.key, this.pet});

  @override
  State<PetFormPage> createState() => _PetFormPageState();
}

class _PetFormPageState extends State<PetFormPage> {
  final _formKey = GlobalKey<FormState>();
  Pet? get _orig => widget.pet;

  late final _name = TextEditingController(text: _orig?.name ?? '');
  late final _weight = TextEditingController(text: _fmt(_orig?.weightKg));
  late final _age = TextEditingController(text: _fmt(_orig?.ageYears));
  late final _kcal = TextEditingController(
      text: (_orig?.foodKcalPerKg ?? 3800).toStringAsFixed(0));
  late final _meals =
      TextEditingController(text: (_orig?.mealsPerDay ?? 2).toString());
  late final _gap =
      TextEditingController(text: ((_orig?.minGapMinutes ?? 180) / 60).toStringAsFixed(1));
  late final _manualGrams = TextEditingController(
      text: widget.pet?.portionG.toStringAsFixed(0) ?? '');

  late String _species = _orig?.species ?? Species.cat;
  late String _breed = _orig?.breed ?? ModelClasses.breedsFor(Species.cat).first;
  late ActivityLevel _activity = _orig?.activity ?? ActivityLevel.normal;
  late bool _manual = _orig?.manualPortion ?? false;
  late String? _image = _orig?.imageBase64;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // New pet: start from the default breed's typical weight and activity.
    if (_orig == null) _applyPreset(fillWeight: true);
  }

  static String _fmt(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
  }

  @override
  void dispose() {
    for (final c in [_name, _weight, _age, _kcal, _meals, _gap, _manualGrams]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isHamster => _species == Species.hamster;

  PortionResult? get _result => PortionCalculator.calculate(
        species: _species,
        weightKg: double.tryParse(_weight.text),
        ageYears: double.tryParse(_age.text),
        activity: _activity,
        foodKcalPerKg: double.tryParse(_kcal.text),
        mealsPerDay: int.tryParse(_meals.text),
      );

  double? get _portion {
    if (_isHamster || _manual) return double.tryParse(_manualGrams.text);
    return _result?.gramsPerMeal;
  }

  Future<void> _pickImage() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 320,
        maxHeight: 320,
        imageQuality: 70,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 600 * 1024) {
        if (mounted) showSnack(context, 'Image too large, choose a smaller one', error: true);
        return;
      }
      setState(() => _image = base64Encode(bytes));
    } catch (e) {
      if (mounted) showSnack(context, 'Could not open image: $e', error: true);
    }
  }

  void _setSpecies(String s) {
    setState(() {
      _species = s;
      _breed = ModelClasses.breedsFor(s).first;
      if (_orig == null) {
        _kcal.text = s == Species.dog ? '3700' : '3800';
        if (s == Species.hamster) _meals.text = '1';
        _applyPreset(fillWeight: true);
      }
    });
  }

  void _setBreed(String breed) {
    setState(() {
      _breed = breed;
      // New pet: fill in the breed's typical values. Existing pet: only the
      // activity level, so a real weight the owner typed is never replaced.
      _applyPreset(fillWeight: _orig == null || _weight.text.trim().isEmpty);
    });
  }

  /// Copies the breed's typical activity (and weight / hamster portion).
  /// Call inside setState.
  void _applyPreset({required bool fillWeight}) {
    final p = BreedPreset.of(_breed);
    if (p == null) return;
    _activity = p.activity;
    if (fillWeight) _weight.text = _fmt(p.typicalKg);
    if (_species == Species.hamster && p.hamsterGramsPerDay != null) {
      final meals = int.tryParse(_meals.text) ?? 1;
      _manualGrams.text = (p.hamsterGramsPerDay! / (meals < 1 ? 1 : meals)).toStringAsFixed(0);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final portion = _portion;
    if (portion == null || portion <= 0) {
      showSnack(context, 'Fill in weight, food energy and meals to get a portion, '
          'or switch on "Set portion manually".', error: true);
      return;
    }
    setState(() => _saving = true);
    final repo = PetRepository.instance;
    final pet = Pet(
      id: _orig?.id ?? repo.newId(),
      name: _name.text.trim(),
      species: _species,
      breed: _breed,
      weightKg: double.tryParse(_weight.text),
      ageYears: double.tryParse(_age.text),
      activity: _activity,
      foodKcalPerKg: double.tryParse(_kcal.text) ?? 3800,
      mealsPerDay: int.tryParse(_meals.text) ?? 2,
      minGapMinutes: ((double.tryParse(_gap.text) ?? 3) * 60).round(),
      manualPortion: _isHamster || _manual,
      portionG: portion,
      enabled: _orig?.enabled ?? true,
      imageBase64: _image,
    );
    try {
      await repo.save(pet);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text('${pet.name} saved')));
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Save failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ImageProvider? image;
    if (_image != null && _image!.isNotEmpty) {
      try {
        image = MemoryImage(base64Decode(_image!));
      } catch (_) {}
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(widget.pet == null ? 'Add pet' : 'Edit ${widget.pet?.name ?? ''}')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            PageBody(
              maxWidth: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: _pickImage,
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 52,
                            backgroundColor:
                                AppTheme.primaryColor.withValues(alpha: 0.14),
                            backgroundImage: image,
                            child: image == null
                                ? Text(Species.emoji(_species),
                                    style: const TextStyle(fontSize: 44))
                                : null,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: CircleAvatar(
                              radius: 17,
                              backgroundColor: AppTheme.primaryColor,
                              child: const Icon(Icons.camera_alt,
                                  size: 18, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Pet name',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SectionHeader('Species & breed',
                      subtitle: 'Must match what the camera model can recognise'),
                  SegmentedButton<String>(
                    segments: [
                      for (final s in Species.all)
                        ButtonSegment(
                          value: s,
                          label: Text(s),
                          icon: Text(Species.emoji(s)),
                        ),
                    ],
                    selected: {_species},
                    onSelectionChanged: (sel) => _setSpecies(sel.first),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: ValueKey('breed-$_species'),
                    initialValue: _breed,
                    decoration: const InputDecoration(
                      labelText: 'Breed (camera class)',
                      prefixIcon: Icon(Icons.category_outlined),
                    ),
                    items: [
                      for (final b in ModelClasses.breedsFor(_species))
                        DropdownMenuItem(value: b, child: Text(ModelClasses.pretty(b))),
                    ],
                    onChanged: (v) {
                      if (v != null) _setBreed(v);
                    },
                  ),
                  _BreedHint(breed: _breed),
                  if (!_isHamster) ...[
                    const SectionHeader('Body & activity'),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _weight,
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Weight (kg)',
                              prefixIcon: Icon(Icons.monitor_weight_outlined),
                            ),
                            onChanged: (_) => setState(() {}),
                            validator: (v) {
                              if (_manual) return null;
                              final d = double.tryParse(v ?? '');
                              return (d == null || d <= 0 || d > 100)
                                  ? '0.1 - 100'
                                  : null;
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _age,
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Age (years)',
                              prefixIcon: Icon(Icons.cake_outlined),
                              helperText: 'e.g. 0.5 for 6 months',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text('Activity level', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    SegmentedButton<ActivityLevel>(
                      segments: [
                        for (final a in ActivityLevel.values)
                          ButtonSegment(value: a, label: Text(a.label)),
                      ],
                      selected: {_activity},
                      onSelectionChanged: (sel) =>
                          setState(() => _activity = sel.first),
                    ),
                  ],
                  const SectionHeader('Feeding plan'),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _meals,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Meals per day',
                            prefixIcon: Icon(Icons.restaurant),
                          ),
                          onChanged: (_) => setState(() {}),
                          validator: (v) {
                            final n = int.tryParse(v ?? '');
                            return (n == null || n < 1 || n > 10) ? '1 - 10' : null;
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _gap,
                          keyboardType:
                              const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Hours between meals',
                            prefixIcon: Icon(Icons.timelapse),
                          ),
                          validator: (v) {
                            final d = double.tryParse(v ?? '');
                            return (d == null || d < 0 || d > 24) ? '0 - 24' : null;
                          },
                        ),
                      ),
                    ],
                  ),
                  if (!_isHamster) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _kcal,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Food energy (kcal per kg)',
                        prefixIcon: Icon(Icons.local_fire_department_outlined),
                        helperText: 'Printed on the food bag, usually 3,500 - 4,200',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Set portion manually'),
                      subtitle: const Text('Skip the calorie calculator'),
                      value: _manual,
                      onChanged: (v) => setState(() {
                        _manual = v;
                        if (v && _manualGrams.text.isEmpty) {
                          _manualGrams.text =
                              (_result?.gramsPerMeal ?? 30).toStringAsFixed(0);
                        }
                      }),
                    ),
                  ],
                  if (_isHamster || _manual) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _manualGrams,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Grams per meal',
                        prefixIcon: const Icon(Icons.scale_outlined),
                        helperText: _isHamster
                            ? 'Adult Syrian hamsters eat roughly 10-12 g of pellets a day'
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (v) {
                        final d = double.tryParse(v ?? '');
                        return (d == null || d <= 0 || d > 500) ? '1 - 500 g' : null;
                      },
                    ),
                  ] else
                    _ResultCard(species: _species, result: _result),
                  const SizedBox(height: 28),
                  ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check),
                    label: Text(_orig == null ? 'Save pet' : 'Update pet'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final String species;
  final PortionResult? result;

  const _ResultCard({required this.species, required this.result});

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.primaryColor, Color(0xFFFFB347)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: r == null
          ? const Text(
              'Enter weight, food energy and meals per day to calculate the portion.',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Your ${species.toLowerCase()} needs about',
                    style: const TextStyle(color: Colors.white70)),
                Text('${r.dailyKcal.toStringAsFixed(0)} kcal / day',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800)),
                const Divider(color: Colors.white30, height: 24),
                Text(
                  '${r.gramsPerMeal.toStringAsFixed(0)} g per meal  '
                  '(${r.gramsPerDay.toStringAsFixed(0)} g per day)',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'RER × ${r.merFactor.toStringAsFixed(1)} (life stage & activity). '
                  'Check with your vet.',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
    );
  }
}

/// "Typical Persian: 3 - 5.5 kg, calm, mostly indoor" under the breed picker.
class _BreedHint extends StatelessWidget {
  final String breed;
  const _BreedHint({required this.breed});

  @override
  Widget build(BuildContext context) {
    final p = BreedPreset.of(breed);
    if (p == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Typical ${ModelClasses.pretty(breed)}: ${p.weightRange}, ${p.temperament}. '
              'Activity is set to ${p.activity.label} - change it if your pet is different.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
