import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/onboarding/screens/onboarding_screen.dart';
import 'features/admin/screens/admin_dashboard.dart';
import 'features/attendance/screens/attendance_history_screen.dart';
import 'features/attendance/screens/action_screen.dart';
import 'features/face_recognition/screens/camera_screen.dart';
import 'features/registration/screens/employee_list_screen.dart';
import 'features/registration/screens/registration_screen.dart';
import 'features/reports/screens/reports_screen.dart';
import 'core/database/database_service.dart';
import 'core/models/employee.dart';

// Global route observer to detect when screens come into focus
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

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
      navigatorObservers: [routeObserver],
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
              builder: (_) => const RootGuardian(),
            );

          case '/action':
            final employee = settings.arguments as Employee;
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) =>
                  ActionScreen(employee: employee),
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

          case '/admin_dash':
            return MaterialPageRoute(
              builder: (_) => const AdminDashboard(),
            );

          case '/user_history':
            final employee = settings.arguments as Employee;
            return MaterialPageRoute(
              builder: (_) => AttendanceHistoryScreen(employee: employee),
            );

          case '/register':
            final editEmployee = settings.arguments as Employee?;
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) => RegistrationScreen(editEmployee: editEmployee),
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

          case '/employee_list':
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

/// The RootGuardian checks if the system has an administrator.
/// If not, it redirects to the Onboarding screen.
class RootGuardian extends StatefulWidget {
  const RootGuardian({super.key});

  @override
  State<RootGuardian> createState() => _RootGuardianState();
}

class _RootGuardianState extends State<RootGuardian> {
  bool? _hasAdmin;

  @override
  void initState() {
    super.initState();
    _checkAdmin();
  }

  Future<void> _checkAdmin() async {
    final hasAdmin = await DatabaseService.instance.hasAdmin();
    if (mounted) setState(() => _hasAdmin = hasAdmin);
  }

  @override
  Widget build(BuildContext context) {
    if (_hasAdmin == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Colors.teal)),
      );
    }

    return _hasAdmin! ? const CameraScreen() : const OnboardingScreen();
  }
}
