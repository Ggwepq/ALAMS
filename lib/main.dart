import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'features/onboarding/screens/onboarding_screen.dart';
import 'features/attendance/screens/selection_screen.dart';
import 'features/admin/screens/admin_dashboard.dart';
import 'features/attendance/screens/attendance_history_screen.dart';
import 'features/attendance/screens/action_screen.dart';
import 'features/face_recognition/screens/camera_screen.dart';
import 'features/registration/screens/employee_list_screen.dart';
import 'features/registration/screens/registration_screen.dart';
import 'features/reports/screens/reports_screen.dart';
import 'core/database/database_service.dart';
import 'core/models/employee.dart';
import 'core/services/sync_service.dart';

import 'features/admin/screens/admin_login_screen.dart';
import 'features/admin/screens/department_management_screen.dart';
import 'features/admin/screens/settings_screen.dart';

final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: '.env');

  // Initialize Supabase
  await Supabase.initialize(
    url:     dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  // Start listening for connectivity to auto-sync
  SyncService.instance.init();

  // On fresh install, pull all data from Supabase
  await SyncService.instance.seedIfNeeded();

  // Always ensure static admin exists
  await DatabaseService.instance.ensureStaticAdmin();

  // Force portrait mode only
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Full immersive mode
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor:        Colors.transparent,
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
          seedColor:  Colors.teal,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        useMaterial3: true,
        fontFamily:   'Roboto',
      ),
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(
              builder: (_) => const RootGuardian(),
            );

          case '/action':
            final args     = settings.arguments as Map<String, dynamic>;
            final employee = args['employee'] as Employee;
            final action   = args['action']   as String?;
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) =>
                  ActionScreen(employee: employee, presetAction: action),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end:   Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/camera':
            final mode = settings.arguments as String? ?? 'SCAN';
            return MaterialPageRoute(
              builder: (_) => CameraScreen(mode: mode),
            );

          case '/admin_login':
            return MaterialPageRoute(
              builder: (_) => const AdminLoginScreen(),
            );

          case '/departments':
            return MaterialPageRoute(
              builder: (_) => const DepartmentManagementScreen(),
            );

          case '/admin_dash':
          case '/admin_dashboard':
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
              pageBuilder: (ctx, anim, secAnim) =>
                  RegistrationScreen(editEmployee: editEmployee),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(1, 0),
                    end:   Offset.zero,
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
                    begin: const Offset(-1, 0),
                    end:   Offset.zero,
                  ).animate(CurvedAnimation(
                      parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/settings':
            return MaterialPageRoute(
              builder: (_) => const SettingsScreen(),
            );

          case '/employee_list':
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) => const EmployeeListScreen(),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end:   Offset.zero,
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
    return _hasAdmin! ? const SelectionScreen() : const OnboardingScreen();
  }
}