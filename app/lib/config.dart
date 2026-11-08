/// Central configuration shared by the whole app.
///
/// The ESP32 firmware and the Raspberry Pi bridge use the SAME paths
/// (see SETUP_GUIDE.md -> "Firebase data layout"). If you rename anything
/// here, rename it in `raspberry_pi/pi_bridge.py` too.
class AppConfig {
  AppConfig._();

  static const String rtdbUrl =
      'https://your-project-default-rtdb.firebaseio.com';

  /// One physical feeder = one device id.
  static const String deviceId = 'feeder01';

  static const String devicePath = 'devices/$deviceId';

  /// A device is shown as "offline" when it has not reported for this long.
  /// The ESP32 sends data every 5 s, the Raspberry Pi a heartbeat every 30 s.
  static const Duration espOfflineAfter = Duration(seconds: 20);
  static const Duration piOfflineAfter = Duration(seconds: 70);

  /// Compartment ids used by the hardware (servo A / servo B).
  static const List<String> compartments = ['A', 'B'];

  static const String supportEmail = 'support@example.com';
}

/// Species the feeder understands.
class Species {
  Species._();
  static const String cat = 'Cat';
  static const String dog = 'Dog';
  static const String hamster = 'Hamster';
  static const List<String> all = [cat, dog, hamster];

  static String emoji(String? species) {
    switch (species) {
      case cat:
        return '🐱';
      case dog:
        return '🐶';
      case hamster:
        return '🐹';
      default:
        return '🐾';
    }
  }
}

/// The 10 classes of the YOLOv11n model trained on Roboflow, grouped by
/// species. The Raspberry Pi uses the same mapping.
class ModelClasses {
  ModelClasses._();

  static const Map<String, List<String>> breedsBySpecies = {
    Species.cat: ['Persian', 'Siamese', 'Tabby', 'Other_Cat'],
    Species.dog: ['Chihuahua', 'German_Shepherd', 'Labrador', 'Other_Dog'],
    Species.hamster: ['Syrian', 'Other_Hamster'],
  };

  static List<String> breedsFor(String species) =>
      breedsBySpecies[species] ?? const [];

  static String speciesOf(String label) {
    for (final entry in breedsBySpecies.entries) {
      if (entry.value.contains(label)) return entry.key;
    }
    return 'Unknown';
  }

  /// "German_Shepherd" -> "German Shepherd", "Other_Cat" -> "Other / mixed".
  static String pretty(String? label) {
    if (label == null || label.isEmpty) return '-';
    if (label.startsWith('Other_')) return 'Other / mixed';
    return label.replaceAll('_', ' ');
  }
}
