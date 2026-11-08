import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';
import 'pages/register_page.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? initError;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    initError = e;
    debugPrint('Firebase init error: $e');
  }
  await themeController.load();
  runApp(PetMonitorApp(initError: initError));
}

class PetMonitorApp extends StatelessWidget {
  final Object? initError;
  const PetMonitorApp({super.key, this.initError});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeController,
      builder: (context, mode, _) => MaterialApp(
        title: 'Smart Pet Monitor',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: mode,
        home: initError != null
            ? _FirebaseErrorScreen(error: initError!)
            : const AuthGate(),
        routes: {
          '/register': (_) => const RegisterPage(),
        },
      ),
    );
  }
}

/// Shows Login or the app depending on the auth state. Because this widget
/// is always the root, logging in/out never needs manual navigation.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.data != null) {
          // Key by uid so all page state resets when another user logs in.
          return HomeShell(key: ValueKey(snapshot.data!.uid));
        }
        return const LoginPage();
      },
    );
  }
}

class _FirebaseErrorScreen extends StatelessWidget {
  final Object error;
  const _FirebaseErrorScreen({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: AppTheme.danger),
              const SizedBox(height: 16),
              Text('Could not connect to Firebase',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Run `flutterfire configure` for this platform and restart.\n\n$error',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
