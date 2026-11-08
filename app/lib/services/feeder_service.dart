import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import '../config.dart';
import '../models/feeder_models.dart';
import '../models/pet.dart';

/// Everything that talks to the Realtime Database lives here, so the pages
/// never hard-code paths.
///
/// Data flow:
///   Flutter --(commands/config)--> RTDB --> Raspberry Pi --MQTT--> ESP32
///   ESP32 --MQTT--> Raspberry Pi --> RTDB (status/logs/feedings) --> Flutter
class FeederService {
  FeederService._();
  static final FeederService instance = FeederService._();

  late final FirebaseDatabase _db = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: AppConfig.rtdbUrl,
  );

  DatabaseReference get _device => _db.ref(AppConfig.devicePath);

  // ---------------------------------------------------------------- streams

  Stream<DeviceStatus> statusStream() => _device
      .child('status')
      .onValue
      .map((e) => DeviceStatus.fromMap(asMap(e.snapshot.value)));

  Stream<FeederConfig> configStream() => _device.child('config').onValue.map(
        (e) => e.snapshot.value == null
            ? FeederConfig.defaults
            : FeederConfig.fromMap(asMap(e.snapshot.value)),
      );

  /// Per-pet stats written by the Pi, keyed by pet id.
  Stream<Map<String, PetStats>> petStatsStream() =>
      _device.child('pets').onValue.map((e) {
        final out = <String, PetStats>{};
        for (final child in e.snapshot.children) {
          final key = child.key;
          if (key == null) continue;
          out[key] = PetStats.fromMap(asMap(asMap(child.value)['stats']));
        }
        return out;
      });

  Stream<List<LogEntry>> logsStream({int limit = 30}) => _device
      .child('logs')
      .orderByChild('ts')
      .limitToLast(limit)
      .onValue
      .map((e) {
        final list = <LogEntry>[];
        for (final child in e.snapshot.children) {
          list.add(LogEntry.fromMap(child.key ?? '', asMap(child.value)));
        }
        return list.reversed.toList(); // newest first
      });

  Stream<List<FeedingRecord>> feedingsStream({required DateTime since}) =>
      _device
          .child('feedings')
          .orderByChild('ts')
          .startAt(since.millisecondsSinceEpoch)
          .onValue
          .map((e) {
        final list = <FeedingRecord>[];
        for (final child in e.snapshot.children) {
          list.add(FeedingRecord.fromMap(child.key ?? '', asMap(child.value)));
        }
        return list.reversed.toList();
      });

  Stream<List<EnvPoint>> envHistoryStream({required DateTime since}) => _device
      .child('history/env')
      .orderByChild('ts')
      .startAt(since.millisecondsSinceEpoch)
      .onValue
      .map((e) {
        final list = <EnvPoint>[];
        for (final child in e.snapshot.children) {
          final p = EnvPoint.fromMap(asMap(child.value));
          if (p != null) list.add(p);
        }
        list.sort((a, b) => a.time.compareTo(b.time));
        return list;
      });

  Stream<List<AlertItem>> alertsStream({int limit = 50}) => _device
      .child('alerts')
      .orderByChild('ts')
      .limitToLast(limit)
      .onValue
      .map((e) {
        final list = <AlertItem>[];
        for (final child in e.snapshot.children) {
          list.add(AlertItem.fromMap(child.key ?? '', asMap(child.value)));
        }
        return list.reversed.toList();
      });

  // --------------------------------------------------------------- commands

  /// Commands are queued under devices/feeder01/commands. The Pi picks each
  /// one up, forwards it to the ESP32 over MQTT and deletes it.
  Future<void> _command(Map<String, dynamic> body) {
    final user = FirebaseAuth.instance.currentUser;
    return _device.child('commands').push().set({
      ...body,
      'ts': ServerValue.timestamp,
      'by': user?.uid ?? 'unknown',
    });
  }

  Future<void> dispense(String compartment, double grams) => _command({
        'action': 'dispense',
        'compartment': compartment,
        'grams': double.parse(grams.toStringAsFixed(1)),
      });

  /// Pump until the bowl is full (75 %), at most 10 s of pumping.
  Future<void> fillWater() => _command({'action': 'water', 'mode': 'fill'});

  /// Save the current water sensor reading as the 'empty' or 'full' point.
  Future<void> calibrateWater(String point) =>
      _command({'action': 'water_cal', 'point': point});

  Future<void> dispenseWater({int seconds = 3}) =>
      _command({'action': 'water', 'seconds': seconds});

  Future<void> tare(String compartment) =>
      _command({'action': 'tare', 'compartment': compartment});

  Future<void> testIdentify() => _command({'action': 'identify'});

  /// Ask the Pi for live pictures for [seconds]. The Live view page repeats
  /// this every 15 s while it is open, and sends 0 when it closes.
  Future<void> requestLive({int seconds = 30}) =>
      _command({'action': 'live', 'seconds': seconds});

  Stream<LiveFrame> liveStream() => _device.child('live').onValue.map(
        (e) => LiveFrame.fromMap(asMap(e.snapshot.value)),
      );

  // ----------------------------------------------------------------- config

  Future<void> updateConfig(Map<String, dynamic> values) =>
      _device.child('config').update(values);

  Future<void> setCompartment(CompartmentConfig c) =>
      _device.child('config/compartments/${c.id}').set(c.toMap());

  Future<void> setFanMode(String mode) => updateConfig({'fanMode': mode});

  /// Camera power: auto (wakes on movement), on (always), off.
  Future<void> setCameraMode(String mode) => updateConfig({'cameraMode': mode});

  // ------------------------------------------------------------------- pets

  Future<void> mirrorPet(Pet pet, String ownerUid) =>
      _device.child('pets/${pet.id}').update(pet.toRtdb(ownerUid));

  /// Clears today's meal counter of one pet (the Pi treats it as a new day).
  Future<void> resetPetStats(String petId) =>
      _device.child('pets/$petId/stats').remove();

  Future<void> deletePetMirror(String petId) =>
      _device.child('pets/$petId').remove();

  // ----------------------------------------------------------------- alerts

  Future<void> markAlertRead(String id) =>
      _device.child('alerts/$id/read').set(true);

  Future<void> markAllAlertsRead(List<AlertItem> alerts) {
    final updates = <String, Object?>{
      for (final a in alerts.where((a) => !a.read)) '${a.id}/read': true,
    };
    if (updates.isEmpty) return Future.value();
    return _device.child('alerts').update(updates);
  }

  Future<void> clearAlerts() => _device.child('alerts').remove();
}
