import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Thin wrapper around Firebase Auth + the user's Firestore profile.
///
/// Usernames are stored in a separate `usernames/{lowercase}` collection so
/// the login page can turn a username into an email WITHOUT having to read
/// every user document (that would expose all emails to the public).
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _auth = FirebaseAuth.instance;
  final _fs = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;

  Future<void> signIn(String emailOrUsername, String password) async {
    final input = emailOrUsername.trim();
    var email = input;
    if (!input.contains('@')) {
      final doc = await _fs.collection('usernames').doc(input.toLowerCase()).get();
      final mapped = doc.data()?['email'] as String?;
      if (mapped == null) {
        throw FirebaseAuthException(
          code: 'user-not-found',
          message: 'No account uses the username "$input".',
        );
      }
      email = mapped;
    }
    await _auth.signInWithEmailAndPassword(email: email, password: password);
    await _ensureUsernameIndex();
  }

  Future<void> register({
    required String username,
    required String email,
    required String password,
    required String flag,
  }) async {
    final key = username.trim().toLowerCase();
    final nameRef = _fs.collection('usernames').doc(key);
    if ((await nameRef.get()).exists) {
      throw FirebaseAuthException(
        code: 'username-taken',
        message: 'That username is already taken.',
      );
    }

    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user!;
    try {
      await _fs.runTransaction((tx) async {
        final snap = await tx.get(nameRef);
        if (snap.exists) {
          throw FirebaseAuthException(
            code: 'username-taken',
            message: 'That username is already taken.',
          );
        }
        tx.set(nameRef, {'uid': user.uid, 'email': email.trim()});
        tx.set(_fs.collection('users').doc(user.uid), {
          'uid': user.uid,
          'username': username.trim(),
          'email': email.trim(),
          'flag': flag,
          'created_at': FieldValue.serverTimestamp(),
        });
      });
      await user.updateDisplayName(username.trim());
    } catch (_) {
      // Roll back the auth account so the user can try again.
      await user.delete();
      rethrow;
    }
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() => _auth.signOut();

  Future<Map<String, dynamic>> profile() async {
    final user = currentUser;
    if (user == null) return {};
    final doc = await _fs.collection('users').doc(user.uid).get();
    return doc.data() ?? {};
  }

  /// Short display name + flag emoji used by the forum.
  Future<({String name, String flag})> displayIdentity() async {
    final user = currentUser;
    final p = await profile();
    final flagString = (p['flag'] as String?) ?? '';
    return (
      name: (p['username'] as String?) ??
          user?.displayName ??
          user?.email?.split('@').first ??
          'Anonymous',
      flag: flagString.isEmpty ? '🏳️' : flagString.split(' ').first,
    );
  }

  /// Accounts created with the old app have no `usernames` entry; create it
  /// on their next login so username login keeps working.
  Future<void> _ensureUsernameIndex() async {
    try {
      final user = currentUser;
      if (user == null) return;
      final p = await profile();
      final username = p['username'] as String?;
      if (username == null || username.isEmpty) return;
      final ref = _fs.collection('usernames').doc(username.toLowerCase());
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set({'uid': user.uid, 'email': user.email});
      }
    } catch (_) {
      // Non-critical.
    }
  }

  /// Human friendly message for Firebase errors.
  static String friendlyError(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'invalid-email':
          return 'That email address is not valid.';
        case 'user-not-found':
        case 'wrong-password':
        case 'invalid-credential':
          return e.message?.contains('username') == true
              ? e.message!
              : 'Incorrect email/username or password.';
        case 'email-already-in-use':
          return 'An account already exists for that email.';
        case 'weak-password':
          return 'Password is too weak (use at least 6 characters).';
        case 'too-many-requests':
          return 'Too many attempts. Please wait a moment and try again.';
        case 'network-request-failed':
          return 'No internet connection.';
        default:
          return e.message ?? 'Authentication failed (${e.code}).';
      }
    }
    if (e is FirebaseException) {
      if (e.code == 'permission-denied') {
        return 'Permission denied - check your Firestore security rules.';
      }
      return e.message ?? e.code;
    }
    return e.toString();
  }
}
