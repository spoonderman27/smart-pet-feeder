import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/pet.dart';
import 'feeder_service.dart';

/// Pet profiles: full copy in Firestore, slim copy in RTDB for the Pi.
class PetRepository {
  PetRepository._();
  static final PetRepository instance = PetRepository._();

  final _fs = FirebaseFirestore.instance;

  String get _uid {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Not logged in');
    return user.uid;
  }

  CollectionReference<Map<String, dynamic>> get _pets =>
      _fs.collection('users').doc(_uid).collection('pets');

  Stream<List<Pet>> petsStream() => _pets.snapshots().map((snap) {
        final list = snap.docs.map((d) => Pet.fromFirestore(d.id, d.data())).toList();
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return list;
      });

  /// Returns a fresh document id for a new pet.
  String newId() => _pets.doc().id;

  Future<void> save(Pet pet) async {
    await _pets.doc(pet.id).set(pet.toFirestore(), SetOptions(merge: true));
    await FeederService.instance.mirrorPet(pet, _uid);
  }

  Future<void> setEnabled(Pet pet, bool enabled) async {
    await _pets.doc(pet.id).update({'enabled': enabled});
    await FeederService.instance.mirrorPet(
      Pet(
        id: pet.id,
        name: pet.name,
        species: pet.species,
        breed: pet.breed,
        portionG: pet.portionG,
        mealsPerDay: pet.mealsPerDay,
        minGapMinutes: pet.minGapMinutes,
        enabled: enabled,
      ),
      _uid,
    );
  }

  Future<void> delete(String petId) async {
    await _pets.doc(petId).delete();
    await FeederService.instance.deletePetMirror(petId);
  }

  /// Re-sync every pet to RTDB (useful after changing the database or
  /// if the Pi was set up after the pets were created).
  Future<int> resyncAll() async {
    final snap = await _pets.get();
    for (final d in snap.docs) {
      await FeederService.instance.mirrorPet(Pet.fromFirestore(d.id, d.data()), _uid);
    }
    return snap.docs.length;
  }
}
