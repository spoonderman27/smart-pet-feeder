// Unit tests for the portion calculator (no Firebase needed).
// Run with:  flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:pet_monitoring/config.dart';
import 'package:pet_monitoring/models/pet.dart';

void main() {
  group('PortionCalculator', () {
    test('RER for a 10 kg dog is about 394 kcal', () {
      expect(PortionCalculator.rer(10), closeTo(393.6, 0.5));
    });

    test('adult neutered cat, 4 kg, normal activity', () {
      final r = PortionCalculator.calculate(
        species: Species.cat,
        weightKg: 4,
        ageYears: 3,
        activity: ActivityLevel.normal,
        foodKcalPerKg: 3800,
        mealsPerDay: 2,
      )!;
      // RER = 70 * 4^0.75 = 198 kcal; x1.2 = 237.6 kcal; / 3.8 kcal/g = 62.5 g/day
      expect(r.dailyKcal, closeTo(237.6, 0.5));
      expect(r.gramsPerDay, closeTo(62.5, 0.5));
      expect(r.gramsPerMeal, closeTo(31.3, 0.5));
    });

    test('puppies get a higher factor than adult dogs', () {
      final puppy = PortionCalculator.merFactor(
          species: Species.dog, ageYears: 0.5, activity: ActivityLevel.normal);
      final adult = PortionCalculator.merFactor(
          species: Species.dog, ageYears: 4, activity: ActivityLevel.normal);
      expect(puppy, greaterThan(adult));
    });

    test('invalid input returns null', () {
      expect(
        PortionCalculator.calculate(
          species: Species.dog,
          weightKg: 0,
          ageYears: 2,
          activity: ActivityLevel.normal,
          foodKcalPerKg: 3700,
          mealsPerDay: 2,
        ),
        isNull,
      );
    });

    test('hamsters use a manual portion (calculator returns null)', () {
      expect(
        PortionCalculator.calculate(
          species: Species.hamster,
          weightKg: 0.15,
          ageYears: 1,
          activity: ActivityLevel.normal,
          foodKcalPerKg: 3500,
          mealsPerDay: 1,
        ),
        isNull,
      );
    });
  });

  group('ModelClasses', () {
    test('maps every YOLO class to a species', () {
      expect(ModelClasses.speciesOf('Chihuahua'), Species.dog);
      expect(ModelClasses.speciesOf('German_Shepherd'), Species.dog);
      expect(ModelClasses.speciesOf('Labrador'), Species.dog);
      expect(ModelClasses.speciesOf('Other_Dog'), Species.dog);
      expect(ModelClasses.speciesOf('Persian'), Species.cat);
      expect(ModelClasses.speciesOf('Siamese'), Species.cat);
      expect(ModelClasses.speciesOf('Tabby'), Species.cat);
      expect(ModelClasses.speciesOf('Other_Cat'), Species.cat);
      expect(ModelClasses.speciesOf('Syrian'), Species.hamster);
      expect(ModelClasses.speciesOf('Other_Hamster'), Species.hamster);
      expect(ModelClasses.speciesOf('Person'), 'Unknown');
    });
  });

  group('BreedPreset', () {
    test('Persian is calm, Siamese is active', () {
      expect(BreedPreset.of('Persian')!.activity, ActivityLevel.low);
      expect(BreedPreset.of('Siamese')!.activity, ActivityLevel.high);
    });

    test('every camera class has a preset', () {
      for (final breeds in ModelClasses.breedsBySpecies.values) {
        for (final b in breeds) {
          expect(BreedPreset.of(b), isNotNull, reason: b);
        }
      }
    });

    test('a typical Persian gets a sensible portion', () {
      final p = BreedPreset.of('Persian')!;
      final r = PortionCalculator.calculate(
        species: Species.cat,
        weightKg: p.typicalKg,
        ageYears: 4,
        activity: p.activity,
        foodKcalPerKg: 3800,
        mealsPerDay: 2,
      )!;
      // 4.5 kg, low activity: about 216 kcal/day, about 57 g/day
      expect(r.gramsPerDay, closeTo(56.9, 1.0));
    });
  });
}
