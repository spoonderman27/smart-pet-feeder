import 'package:flutter/foundation.dart';

import '../config.dart';

// ---------------------------------------------------------------------------
// Small helpers to read Realtime Database values safely.
// RTDB returns Map<Object?, Object?> on mobile and Map<String, dynamic> on web.
// ---------------------------------------------------------------------------

Map<String, dynamic> asMap(Object? value) {
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  return <String, dynamic>{};
}

double? asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

bool asBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.toLowerCase() == 'true';
  return fallback;
}

String? asString(Object? value) => value?.toString();

DateTime? fromMillis(Object? value) {
  final ms = asInt(value);
  if (ms == null || ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

bool isRecent(DateTime? time, Duration within) {
  if (time == null) return false;
  return DateTime.now().difference(time).abs() <= within;
}

// ---------------------------------------------------------------------------
// Live status written by the Raspberry Pi bridge (from ESP32 telemetry).
// Path: devices/feeder01/status
// ---------------------------------------------------------------------------

@immutable
class Detection {
  final String label;
  final String species;
  final double confidence;
  final DateTime? time;
  final String decision; // dispensed | denied | unknown
  final String message;
  final String? imageBase64;

  const Detection({
    required this.label,
    required this.species,
    required this.confidence,
    required this.time,
    required this.decision,
    required this.message,
    this.imageBase64,
  });

  factory Detection.fromMap(Map<String, dynamic> m) => Detection(
        label: asString(m['label']) ?? '-',
        species: asString(m['species']) ?? 'Unknown',
        confidence: asDouble(m['confidence']) ?? 0,
        time: fromMillis(m['ts']),
        decision: asString(m['decision']) ?? '',
        message: asString(m['message']) ?? '',
        imageBase64: asString(m['image']),
      );
}

@immutable
class DeviceStatus {
  final bool espOnline;
  final DateTime? espLastSeen;
  final DateTime? piLastSeen;
  final double? temperature;
  final double? humidity;
  final bool fanOn;
  final bool pumpOn;
  final String fanMode;
  final double? waterPct;
  final bool waterLow;
  final bool reservoirEmpty;
  final Map<String, double?> bowlGrams;
  final bool feederPresence;
  final bool waterPresence;
  final bool dispensing;
  final int? rssi;
  final Detection? lastDetection;
  final int? waterRaw; // raw water sensor reading (for calibration)
  final int? waterCalEmpty; // saved EMPTY calibration point
  final int? waterCalFull; // saved FULL calibration point
  final bool cameraOn; // camera currently running on the Pi
  final String cameraMode; // auto | on | off (as the Pi applied it)
  final DateTime? fanOnSince; // when the cooling fan turned on (null = off)

  const DeviceStatus({
    this.espOnline = false,
    this.espLastSeen,
    this.piLastSeen,
    this.temperature,
    this.humidity,
    this.fanOn = false,
    this.pumpOn = false,
    this.fanMode = 'auto',
    this.waterPct,
    this.waterLow = false,
    this.reservoirEmpty = false,
    this.bowlGrams = const {},
    this.feederPresence = false,
    this.waterPresence = false,
    this.dispensing = false,
    this.rssi,
    this.lastDetection,
    this.cameraOn = false,
    this.cameraMode = 'auto',
    this.waterRaw,
    this.waterCalEmpty,
    this.waterCalFull,
    this.fanOnSince,
  });

  static const empty = DeviceStatus();

  /// Short camera state for the UI: "Camera on", "Camera resting", ...
  String get cameraLabel {
    if (!cameraOnline) return 'Camera offline';
    if (cameraMode == 'off') return 'Camera off';
    return cameraOn ? 'Camera on' : 'Camera resting';
  }

  /// ESP32 counts as online only if the bridge says so AND data is fresh.
  bool get feederOnline =>
      espOnline && isRecent(espLastSeen, AppConfig.espOfflineAfter);

  bool get cameraOnline => isRecent(piLastSeen, AppConfig.piOfflineAfter);

  /// How long the fan has been running, e.g. "12 min" (null if off / unknown).
  String? get fanRunningFor {
    if (!fanOn || fanOnSince == null) return null;
    final d = DateTime.now().difference(fanOnSince!);
    if (d.inMinutes < 1) return '<1 min';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    return '${d.inHours} h ${d.inMinutes % 60} min';
  }

  factory DeviceStatus.fromMap(Map<String, dynamic> m) {
    final bowls = asMap(m['bowls']);
    final det = asMap(m['lastDetection']);
    return DeviceStatus(
      espOnline: asBool(m['espOnline']),
      espLastSeen: fromMillis(m['espLastSeen']),
      piLastSeen: fromMillis(m['piLastSeen']),
      temperature: asDouble(m['temperature']),
      humidity: asDouble(m['humidity']),
      fanOn: asBool(m['fanOn']),
      pumpOn: asBool(m['pumpOn']),
      fanMode: asString(m['fanMode']) ?? 'auto',
      waterPct: asDouble(m['waterPct']),
      waterLow: asBool(m['waterLow']),
      reservoirEmpty: asBool(m['reservoirEmpty']),
      bowlGrams: {
        for (final c in AppConfig.compartments) c: asDouble(bowls[c]),
      },
      feederPresence: asBool(m['feederPresence']),
      waterPresence: asBool(m['waterPresence']),
      dispensing: asBool(m['dispensing']),
      rssi: asInt(m['rssi']),
      lastDetection: det.isEmpty ? null : Detection.fromMap(det),
      cameraOn: asBool(m['cameraOn']),
      waterRaw: asInt(m['waterRaw']),
      waterCalEmpty: asInt(m['waterCalEmpty']),
      waterCalFull: asInt(m['waterCalFull']),
      cameraMode: asString(m['cameraMode']) ?? 'auto',
      fanOnSince: fromMillis(m['fanOnSince']),
    );
  }
}

// ---------------------------------------------------------------------------
// Feeder configuration written by the app. Path: devices/feeder01/config
// ---------------------------------------------------------------------------

@immutable
class CompartmentConfig {
  final String id; // A or B
  final String? species; // Cat / Dog / Hamster / null = unused
  final String label; // e.g. "Royal Canin Kitten"

  const CompartmentConfig({required this.id, this.species, this.label = ''});

  factory CompartmentConfig.fromMap(String id, Map<String, dynamic> m) {
    final s = asString(m['species']);
    return CompartmentConfig(
      id: id,
      species: (s == null || s.isEmpty || s == 'None') ? null : s,
      label: asString(m['label']) ?? '',
    );
  }

  Map<String, dynamic> toMap() => {'species': species ?? 'None', 'label': label};

  String get displayName =>
      label.isNotEmpty ? label : (species == null ? 'Not set' : '$species food');
}

@immutable
class FeederConfig {
  final Map<String, CompartmentConfig> compartments;
  final double tempThreshold;
  final String fanMode; // auto | on | off
  final bool waterAuto;
  final int presenceCm;
  final double minConfidence;
  final String cameraMode; // auto | on | off
  final int wakeCm; // auto mode: camera wakes when something is closer than this
  final bool demoMode; // ignore meal limits + gap between meals (presentations)
  final bool petTopUp; // ultrasonic sensor #2 tops up the bowl when a pet drinks

  const FeederConfig({
    required this.compartments,
    this.tempThreshold = 30,
    this.fanMode = 'auto',
    this.waterAuto = true,
    this.presenceCm = 25,
    this.minConfidence = 0.5,
    this.cameraMode = 'auto',
    this.wakeCm = 30,
    this.demoMode = false,
    this.petTopUp = true,
  });

  static FeederConfig get defaults => FeederConfig(compartments: {
        for (final c in AppConfig.compartments) c: CompartmentConfig(id: c),
      });

  factory FeederConfig.fromMap(Map<String, dynamic> m) {
    final comps = asMap(m['compartments']);
    return FeederConfig(
      compartments: {
        for (final c in AppConfig.compartments)
          c: CompartmentConfig.fromMap(c, asMap(comps[c])),
      },
      tempThreshold: asDouble(m['tempThreshold']) ?? 30,
      fanMode: asString(m['fanMode']) ?? 'auto',
      waterAuto: asBool(m['waterAuto'], true),
      presenceCm: asInt(m['presenceCm']) ?? 25,
      minConfidence: asDouble(m['minConfidence']) ?? 0.5,
      cameraMode: asString(m['cameraMode']) ?? 'auto',
      wakeCm: asInt(m['wakeCm']) ?? 30,
      demoMode: asBool(m['demoMode']),
      petTopUp: asBool(m['petTopUp'], true),
    );
  }

  /// Which compartment holds food for this species (null if none).
  String? compartmentFor(String species) {
    for (final c in compartments.values) {
      if (c.species == species) return c.id;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Live view picture uploaded by the Pi about once per second while the
// Live view page is open. Path: devices/feeder01/live
// ---------------------------------------------------------------------------

@immutable
class LiveFrame {
  final bool active;
  final String state; // starting | streaming | stopped | off
  final DateTime? time;
  final String? imageBase64;

  const LiveFrame({
    this.active = false,
    this.state = 'stopped',
    this.time,
    this.imageBase64,
  });

  factory LiveFrame.fromMap(Map<String, dynamic> m) => LiveFrame(
        active: asBool(m['active']),
        state: asString(m['state']) ?? 'stopped',
        time: fromMillis(m['ts']),
        imageBase64: asString(m['image']),
      );

  /// A picture newer than a few seconds counts as live.
  bool get isFresh =>
      imageBase64 != null &&
      imageBase64!.isNotEmpty &&
      isRecent(time, const Duration(seconds: 6));
}

// ---------------------------------------------------------------------------
// Logs, feedings, alerts, environment history.
// ---------------------------------------------------------------------------

@immutable
class LogEntry {
  final String id;
  final DateTime? time;
  final String type; // feed | water | fan | detect | system | command
  final String level; // info | warn | error
  final String message;

  const LogEntry({
    required this.id,
    required this.time,
    required this.type,
    required this.level,
    required this.message,
  });

  factory LogEntry.fromMap(String id, Map<String, dynamic> m) => LogEntry(
        id: id,
        time: fromMillis(m['ts']),
        type: asString(m['type']) ?? 'system',
        level: asString(m['level']) ?? 'info',
        message: asString(m['message']) ?? '',
      );

  /// Things the owner needs to know (shown on the Dashboard). Routine system
  /// messages such as "Feeder booted" or "Live view opened" are only in the
  /// full log on the History page.
  bool get isImportant {
    if (level == 'warn' || level == 'error') return true;
    switch (type) {
      case 'feed':
      case 'detect':
      case 'fan':
        return true;
      case 'water':
        return !message.startsWith('A pet came to drink');
      default: // system, command, camera
        return false;
    }
  }
}

@immutable
class FeedingRecord {
  final String id;
  final DateTime? time;
  final String? petId;
  final String petName;
  final String species;
  final String compartment;
  final double targetG;
  final double dispensedG;
  final double? eatenG;
  final String source; // auto | manual
  final bool ok;
  final String reason;

  const FeedingRecord({
    required this.id,
    required this.time,
    this.petId,
    required this.petName,
    required this.species,
    required this.compartment,
    required this.targetG,
    required this.dispensedG,
    this.eatenG,
    required this.source,
    required this.ok,
    required this.reason,
  });

  factory FeedingRecord.fromMap(String id, Map<String, dynamic> m) =>
      FeedingRecord(
        id: id,
        time: fromMillis(m['ts']),
        petId: asString(m['petId']),
        petName: asString(m['petName']) ?? 'Manual',
        species: asString(m['species']) ?? '-',
        compartment: asString(m['compartment']) ?? '-',
        targetG: asDouble(m['targetG']) ?? 0,
        dispensedG: asDouble(m['dispensedG']) ?? 0,
        eatenG: asDouble(m['eatenG']),
        source: asString(m['source']) ?? 'auto',
        ok: asBool(m['ok'], true),
        reason: asString(m['reason']) ?? '',
      );
}

@immutable
class AlertItem {
  final String id;
  final DateTime? time;
  final String type;
  final String title;
  final String message;
  final bool read;

  const AlertItem({
    required this.id,
    required this.time,
    required this.type,
    required this.title,
    required this.message,
    required this.read,
  });

  factory AlertItem.fromMap(String id, Map<String, dynamic> m) => AlertItem(
        id: id,
        time: fromMillis(m['ts']),
        type: asString(m['type']) ?? 'info',
        title: asString(m['title']) ?? 'Alert',
        message: asString(m['message']) ?? '',
        read: asBool(m['read']),
      );
}

@immutable
class EnvPoint {
  final DateTime time;
  final double? temperature;
  final double? humidity;

  const EnvPoint(this.time, this.temperature, this.humidity);

  static EnvPoint? fromMap(Map<String, dynamic> m) {
    final t = fromMillis(m['ts']);
    if (t == null) return null;
    return EnvPoint(t, asDouble(m['temperature']), asDouble(m['humidity']));
  }
}
