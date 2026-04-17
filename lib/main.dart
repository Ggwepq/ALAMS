import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/attendance/screens/action_screen.dart';
import 'features/face_recognition/screens/camera_screen.dart';
import 'features/registration/screens/employee_list_screen.dart';
import 'features/registration/screens/registration_screen.dart';
import 'features/reports/screens/reports_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force portrait mode only — attendance kiosks should not rotate
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Full immersive mode — hide status/nav bars for a kiosk feel
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    const ProviderScope(
      child: AlamsApp(),
    ),
  );
}

class AlamsApp extends StatelessWidget {
  const AlamsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ALAMS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      // Named routes
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => const CameraScreen(),
            );

          case '/action':
            final name = settings.arguments as String? ?? 'Unknown';
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) =>
                  ActionScreen(employeeName: name),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/register':
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) => const RegistrationScreen(),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/reports':
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) => const ReportsScreen(),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(-1, 0), // slide in from left
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/employees':
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) => const EmployeeListScreen(),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1), // slide up from bottom
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          default:
            return MaterialPageRoute(
              builder: (_) => const CameraScreen(),
            );
        }
      },
    );
  }
}
