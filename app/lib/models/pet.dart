import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../config.dart';
import 'feeder_models.dart';

enum ActivityLevel { low, normal, high }

extension ActivityLevelX on ActivityLevel {
  String get label {
    switch (this) {
      case ActivityLevel.low:
        return 'Low';
      case ActivityLevel.normal:
        return 'Normal';
      case ActivityLevel.high:
        return 'High';
    }
  }

  static ActivityLevel parse(String? value) {
    switch (value) {
      case 'low':
      case 'Less Active':
        return ActivityLevel.low;
      case 'high':
      case 'Very Active':
        return ActivityLevel.high;
      default:
        return ActivityLevel.normal;
    }
  }
}

/// Result of the portion calculator.
class PortionResult {
  final double dailyKcal;
  final double gramsPerDay;
  final double gramsPerMeal;
  final double merFactor;

  const PortionResult({
    required this.dailyKcal,
    required this.gramsPerDay,
    required this.gramsPerMeal,
    required this.merFactor,
  });
}

/// Daily energy requirement based on the standard veterinary formula:
///   RER (kcal/day) = 70 x bodyWeightKg^0.75
///   MER = RER x life-stage/activity factor
///   grams/day = MER / (food kcal per kg / 1000)
///
/// Factors follow common WSAVA / AAHA guideline ranges. Always confirm the
/// final amount with a vet - this is a starting point, not medical advice.
class PortionCalculator {
  PortionCalculator._();

  static double rer(double weightKg) => 70 * pow(weightKg, 0.75).toDouble();

  static double merFactor({
    required String species,
    required double ageYears,
    required ActivityLevel activity,
  }) {
    if (species == Species.dog) {
      if (ageYears < 0.33) return 3.0; // puppy under 4 months
      if (ageYears < 1) return 2.0; // puppy 4-12 months
      double f;
      switch (activity) {
        case ActivityLevel.low:
          f = 1.4;
          break;
        case ActivityLevel.normal:
          f = 1.6;
          break;
        case ActivityLevel.high:
          f = 2.0;
          break;
      }
      if (ageYears >= 8) f *= 0.9; // senior
      return f;
    }
    if (species == Species.cat) {
      if (ageYears < 1) return 2.5; // kitten
      switch (activity) {
        case ActivityLevel.low:
          return 1.0;
        case ActivityLevel.normal:
          return 1.2;
        case ActivityLevel.high:
          return 1.4;
      }
    }
    return 1.0;
  }

  /// Returns null when the inputs are not usable.
  static PortionResult? calculate({
    required String species,
    required double? weightKg,
    required double? ageYears,
    required ActivityLevel activity,
    required double? foodKcalPerKg,
    required int? mealsPerDay,
  }) {
    if (species == Species.hamster) return null;
    if (weightKg == null || weightKg <= 0) return null;
    if (foodKcalPerKg == null || foodKcalPerKg <= 0) return null;
    if (mealsPerDay == null || mealsPerDay <= 0) return null;
    final factor = merFactor(
      species: species,
      ageYears: ageYears ?? 3,
      activity: activity,
    );
    final kcal = rer(weightKg) * factor;
    final gramsPerDay = kcal / (foodKcalPerKg / 1000);
    return PortionResult(
      dailyKcal: kcal,
      gramsPerDay: gramsPerDay,
      gramsPerMeal: gramsPerDay / mealsPerDay,
      merFactor: factor,
    );
  }
}

/// A pet profile. Stored in Firestore (users/{uid}/pets/{id}) with all
/// details, and mirrored to RTDB (devices/feeder01/pets/{id}) with only the
/// fields the Raspberry Pi needs to make a feeding decision.
class Pet {
  final String id;
  final String name;
  final String species;
  final String breed; // one of ModelClasses.breedsFor(species)
  final double? weightKg;
  final double? ageYears;
  final ActivityLevel activity;
  final double foodKcalPerKg;
  final int mealsPerDay;
  final int minGapMinutes;
  final bool manualPortion;
  final double portionG; // grams per meal actually used by the feeder
  final bool enabled;
  final String? imageBase64;

  const Pet({
    required this.id,
    required this.name,
    required this.species,
    required this.breed,
    this.weightKg,
    this.ageYears,
    this.activity = ActivityLevel.normal,
    this.foodKcalPerKg = 3800,
    this.mealsPerDay = 2,
    this.minGapMinutes = 180,
    this.manualPortion = false,
    required this.portionG,
    this.enabled = true,
    this.imageBase64,
  });

  factory Pet.fromFirestore(String id, Map<String, dynamic> d) {
    final species = asString(d['species']) ?? Species.cat;
    final breeds = ModelClasses.breedsFor(species);
    var breed = asString(d['breed']) ?? '';
    if (!breeds.contains(breed)) {
      breed = breeds.isNotEmpty ? breeds.last : '';
    }
    // Older profiles stored "cups"; convert roughly (1 cup of kibble ~ 100 g).
    double portion = asDouble(d['portion_g']) ?? 0;
    if (portion <= 0) {
      final cups = asDouble(d['feed_portion_cups']);
      final grams = asDouble(d['grams_per_meal']);
      portion = grams ?? ((cups ?? 0.5) * 100);
    }
    return Pet(
      id: id,
      name: asString(d['name']) ?? 'Unnamed',
      species: species,
      breed: breed,
      weightKg: asDouble(d['weight']),
      ageYears: asDouble(d['age']),
      activity: ActivityLevelX.parse(asString(d['activity_level'])),
      foodKcalPerKg: asDouble(d['food_kcal_per_kg']) ??
          (species == Species.dog ? 3700 : 3800),
      mealsPerDay: asInt(d['meals_per_day']) ?? 2,
      minGapMinutes: asInt(d['min_gap_minutes']) ?? 180,
      manualPortion: asBool(d['manual_portion'] ?? d['is_manual_override']),
      portionG: portion,
      enabled: asBool(d['enabled'], true),
      imageBase64: asString(d['image_base64']),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'species': species,
        'breed': breed,
        'weight': weightKg,
        'age': ageYears,
        'activity_level': activity.name,
        'food_kcal_per_kg': foodKcalPerKg,
        'meals_per_day': mealsPerDay,
        'min_gap_minutes': minGapMinutes,
        'manual_portion': manualPortion,
        'portion_g': double.parse(portionG.toStringAsFixed(1)),
        'enabled': enabled,
        'image_base64': imageBase64,
        'updated_at': FieldValue.serverTimestamp(),
      };

  /// Slim copy for the Raspberry Pi. Uses update() so the Pi's
  /// `stats` child (meals today etc.) is never overwritten.
  Map<String, dynamic> toRtdb(String ownerUid) => {
        'name': name,
        'species': species,
        'breed': breed,
        'portionG': double.parse(portionG.toStringAsFixed(1)),
        'mealsPerDay': mealsPerDay,
        'minGapMinutes': minGapMinutes,
        'enabled': enabled,
        'ownerUid': ownerUid,
      };
}

/// Per-pet counters maintained by the Raspberry Pi
/// (devices/feeder01/pets/{id}/stats).
class PetStats {
  final int mealsToday;
  final double gramsToday;
  final DateTime? lastFedAt;

  const PetStats({this.mealsToday = 0, this.gramsToday = 0, this.lastFedAt});

  factory PetStats.fromMap(Map<String, dynamic> m) {
    // The Pi stores the date the counters belong to; ignore stale counters.
    final today = DateTime.now();
    final key =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final sameDay = asString(m['date']) == key;
    return PetStats(
      mealsToday: sameDay ? (asInt(m['mealsToday']) ?? 0) : 0,
      gramsToday: sameDay ? (asDouble(m['gramsToday']) ?? 0) : 0,
      lastFedAt: fromMillis(m['lastFedAt']),
    );
  }
}

/// Typical adult values per camera class, used to pre-fill the pet form.
/// These are general breed averages for a starting point only; the owner
/// should enter the pet's real weight and check the portion with a vet.
class BreedPreset {
  final String breed;
  final double typicalKg;
  final String weightRange;
  final ActivityLevel activity;
  final String temperament;
  final double? hamsterGramsPerDay; // hamsters only

  const BreedPreset({
    required this.breed,
    required this.typicalKg,
    required this.weightRange,
    required this.activity,
    required this.temperament,
    this.hamsterGramsPerDay,
  });

  static const Map<String, BreedPreset> all = {
    'Persian': BreedPreset(
        breed: 'Persian', typicalKg: 4.5, weightRange: '3 - 5.5 kg',
        activity: ActivityLevel.low, temperament: 'calm, mostly indoor'),
    'Siamese': BreedPreset(
        breed: 'Siamese', typicalKg: 4.0, weightRange: '3 - 5 kg',
        activity: ActivityLevel.high, temperament: 'very active and playful'),
    'Tabby': BreedPreset(
        breed: 'Tabby', typicalKg: 4.5, weightRange: '3.5 - 5.5 kg',
        activity: ActivityLevel.normal, temperament: 'average domestic cat'),
    'Other_Cat': BreedPreset(
        breed: 'Other_Cat', typicalKg: 4.5, weightRange: '3.5 - 5.5 kg',
        activity: ActivityLevel.normal, temperament: 'average domestic cat'),
    'Chihuahua': BreedPreset(
        breed: 'Chihuahua', typicalKg: 2.5, weightRange: '1.5 - 3 kg',
        activity: ActivityLevel.normal, temperament: 'small, lively indoors'),
    'German_Shepherd': BreedPreset(
        breed: 'German_Shepherd', typicalKg: 32, weightRange: '22 - 40 kg',
        activity: ActivityLevel.high, temperament: 'large working dog, very active'),
    'Labrador': BreedPreset(
        breed: 'Labrador', typicalKg: 30, weightRange: '25 - 36 kg',
        activity: ActivityLevel.normal, temperament: 'active but gains weight easily'),
    'Other_Dog': BreedPreset(
        breed: 'Other_Dog', typicalKg: 15, weightRange: '5 - 30 kg',
        activity: ActivityLevel.normal, temperament: 'enter the real weight'),
    'Syrian': BreedPreset(
        breed: 'Syrian', typicalKg: 0.15, weightRange: '100 - 175 g',
        activity: ActivityLevel.normal, temperament: 'eats about 10 - 12 g a day',
        hamsterGramsPerDay: 11),
    'Other_Hamster': BreedPreset(
        breed: 'Other_Hamster', typicalKg: 0.05, weightRange: '25 - 60 g (dwarf)',
        activity: ActivityLevel.normal, temperament: 'eats about 5 - 7 g a day',
        hamsterGramsPerDay: 6),
  };

  static BreedPreset? of(String breed) => all[breed];
}
