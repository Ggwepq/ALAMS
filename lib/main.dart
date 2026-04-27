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

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  // ✅ Create container BEFORE init() so setContainer is ready
  final container = ProviderContainer();
  SyncService.instance.setContainer(container);

  // Start connectivity listener and real-time subscriptions
  SyncService.instance.init();

  // Pull latest data from Supabase on every startup
  await SyncService.instance.seedIfNeeded();

  // Ensure static admin exists locally
  await DatabaseService.instance.ensureStaticAdmin();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    UncontrolledProviderScope(container: container, child: const AlamsApp()),
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
      initialRoute: '/',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/':
            return MaterialPageRoute(builder: (_) => const RootGuardian());

          case '/action':
            final args = settings.arguments as Map<String, dynamic>;
            final employee = args['employee'] as Employee;
            final action = args['action'] as String?;
            return PageRouteBuilder(
              pageBuilder: (ctx, anim, secAnim) =>
                  ActionScreen(employee: employee, presetAction: action),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, 1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/camera':
            final mode = settings.arguments as String? ?? 'SCAN';
            return MaterialPageRoute(builder: (_) => CameraScreen(mode: mode));

          case '/admin_login':
            return MaterialPageRoute(builder: (_) => const AdminLoginScreen());

          case '/companies':
            return MaterialPageRoute(
              builder: (_) => const DepartmentManagementScreen(),
            );

          case '/admin_dash':
          case '/admin_dashboard':
            return MaterialPageRoute(builder: (_) => const AdminDashboard());

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
                  position:
                      Tween<Offset>(
                        begin: const Offset(1, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
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
                  position:
                      Tween<Offset>(
                        begin: const Offset(-1, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          case '/settings':
            return MaterialPageRoute(builder: (_) => const SettingsScreen());

          case '/employee_list':
            return PageRouteBuilder(
              settings:
                  settings, // ← FIX: pass settings so ModalRoute.of(context)?.settings.arguments works
              pageBuilder: (ctx, anim, secAnim) => const EmployeeListScreen(),
              transitionsBuilder: (ctx, anim, secAnim, child) {
                return SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, 1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                  child: child,
                );
              },
              transitionDuration: const Duration(milliseconds: 350),
            );

          default:
            return MaterialPageRoute(builder: (_) => const CameraScreen());
        }
      },
      builder: (context, child) {
        return WatermarkOverlay(child: child!);
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

class WatermarkOverlay extends StatefulWidget {
  final Widget child;

  const WatermarkOverlay({super.key, required this.child});

  @override
  State<WatermarkOverlay> createState() => _WatermarkOverlayState();
}

class _WatermarkOverlayState extends State<WatermarkOverlay> {
  bool _showWatermark = true;

  @override
  void initState() {
    super.initState();
    _checkWatermark();
  }

  Future<void> _checkWatermark() async {
    final enabled = await DatabaseService.instance.getSetting(
      'watermark_enabled',
      '1',
    );
    if (mounted) {
      setState(() => _showWatermark = enabled == '1');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_showWatermark)
          IgnorePointer(
            child: CustomPaint(
              painter: WatermarkPainter(),
              size: Size.infinite,
            ),
          ),
      ],
    );
  }
}

class WatermarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const text = 'ODDS';
    const textStyle = TextStyle(
      color: Color(0x80FFFFFF), // 50% opacity white
      fontSize: 28,
      fontWeight: FontWeight.bold,
    );

    final textPainter = TextPainter(
      text: const TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();

    const double spacingX = 180.0;
    const double spacingY = 180.0;

    canvas.save();

    // Rotate around screen center to keep things centered
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-0.5);
    canvas.translate(-size.width / 2, -size.height / 2);

    // Large enough range to cover the screen even when rotated
    for (double x = -size.width; x < size.width * 2; x += spacingX) {
      for (double y = -size.height; y < size.height * 2; y += spacingY) {
        textPainter.paint(canvas, Offset(x, y));
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
