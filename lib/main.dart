import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'home_page.dart';
import 'round_utils.dart';
import 'd1_client.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ===================== MAIN =======================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize timezone in background to avoid blocking
  try {
    tz.initializeTimeZones();
  } catch (e) {
    debugPrint('Timezone init error: $e');
  }

  // Initialize notifications early but non-blocking
  _initializeNotifications();

  runApp(const VeriPatrolApp());
}

// ===================== NOTIFICATION SETUP =======================

Future<void> _initializeNotifications() async {
  try {
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    await flutterLocalNotificationsPlugin.initialize(
      const InitializationSettings(android: androidInit),
    );

    final android = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        'patrol_channel_id',
        'Patrol Alerts',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('alert'),
        enableVibration: true,
      ),
    );
  } catch (e) {
    debugPrint('Notification initialization error: $e');
  }
}

// ===================== APP =======================

class VeriPatrolApp extends StatelessWidget {
  const VeriPatrolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VeriPatrol',
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: const Color(0xFF005C97),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const LoginScreen(),
        '/home': (context) {
          final args = ModalRoute.of(context)?.settings.arguments
              as Map<String, dynamic>?;

          return HomePage(
            guardName: args?['guardName'] ?? '',
            factoryCode: args?['factoryCode'] ?? '',
            isMaster: args?['isMaster'] ?? false,
            canScan: args?['canScan'] ?? false,
          );
        },
      },
    );
  }
}

// ===================== LOGIN =======================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _pinCtrl = TextEditingController();

  bool _loading = false;

  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(milliseconds: 500), () async {
      await _requestNotificationPermission();
      await _scheduleNotifications();
    });
  }

  @override
  void dispose() {
    _pinCtrl.dispose();

    super.dispose();
  }

// ================= INTERNET ==================

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();

    return !result.contains(ConnectivityResult.none);
  }

// ================= TIME ==================

  DateTime _getNextRound(DateTime dt) {
    if (dt.minute <= 30) {
      return DateTime(dt.year, dt.month, dt.day, dt.hour, 30);
    } else {
      return DateTime(dt.year, dt.month, dt.day, dt.hour + 1, 0);
    }
  }

// ================= NOTIFICATION ==================

  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.status;

    if (!status.isGranted) {
      final result = await Permission.notification.request();
      if (!result.isGranted) {
        debugPrint('Notification permission denied');
      }
    }
  }

  Future<void> _scheduleNotifications() async {
    await flutterLocalNotificationsPlugin.cancelAll();

    final now = tz.TZDateTime.now(tz.local);
    final rounds = buildPatrolRounds(DateTime.now());

    for (int i = 0; i < rounds.length && i < 24; i++) {
      final windowStart = getScanWindowStart(rounds[i].time);
      final timeUtc = windowStart.toUtc().subtract(const Duration(minutes: 5));
      final time = tz.TZDateTime.from(timeUtc, tz.local);

      if (time.isBefore(now)) continue;

      await flutterLocalNotificationsPlugin.zonedSchedule(
        i,
        "PATROL ALERT",
        "⏰ Patrol starts in 5 minutes!",
        time,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'patrol_channel_id',
            'Patrol Alerts',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            sound: RawResourceAndroidNotificationSound('alert'),
            enableVibration: true,
            fullScreenIntent: false,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

// ================= LOGIN ==================

  Future<void> _login(String pin) async {
    if (pin.length != 4) return;

    if (!await _isOnline()) {
      _pinCtrl.clear();

      _showMsg("No Internet");

      return;
    }

    setState(() => _loading = true);

    try {
      final adminList = await D1Client.query(
        "SELECT name, role FROM login_info WHERE user_pin = ? AND is_active = 1 LIMIT 1",
        [pin],
      );
      final admin = adminList.isNotEmpty ? adminList[0] : null;

      if (admin != null) {
        _goHome(
          admin['name'],
          'ADMIN',
          true,
          true,
        );

        return;
      }

      final guardList = await D1Client.query(
        "SELECT security_name, factory FROM security_users WHERE security_password = ? LIMIT 1",
        [pin],
      );
      final guard = guardList.isNotEmpty ? guardList[0] : null;

      if (guard != null) {
        _goHome(
          guard['security_name'],
          guard['factory'],
          false,
          true,
        );

        return;
      }

      _pinCtrl.clear();

      _showMsg("INVALID PIN");
    } catch (e) {
      debugPrint("Login error: $e");
      _showMsg("Server Error");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

// ================= UI HELPERS ==================

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _goHome(
    String name,
    String factory,
    bool isAdmin,
    bool canScan,
  ) {
    Navigator.pushReplacementNamed(
      context,
      '/home',
      arguments: {
        'guardName': name,
        'factoryCode': factory,
        'isMaster': isAdmin,
        'canScan': canScan,
      },
    );
  }

// ================= UI ==================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF005C97),
              Color(0xFF363795),
            ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // LOGO
                Container(
                  height: 120,
                  width: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 10,
                        offset: Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Image.asset(
                      "assets/logo.png",
                      fit: BoxFit.contain,
                      errorBuilder: (c, e, s) => const Icon(
                        Icons.security,
                        size: 70,
                        color: Color(0xFF005C97),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                const Text(
                  "VeriPatrol",
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),

                const SizedBox(height: 6),

                const Text(
                  "Security Monitoring System",
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                ),

                const SizedBox(height: 40),

                // LOGIN CARD
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 12,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const Text(
                        "LOGIN",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF005C97),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // PIN FIELD
                      TextField(
                        controller: _pinCtrl,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        obscureText: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          letterSpacing: 8,
                          fontWeight: FontWeight.bold,
                        ),
                        onChanged: _login,
                        decoration: InputDecoration(
                          hintText: "••••",
                          counterText: "",
                          filled: true,
                          fillColor: Colors.grey[100],
                          prefixIcon: const Icon(
                            Icons.lock,
                            color: Color(0xFF005C97),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF005C97),
                              width: 2,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // LOGIN BUTTON
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => _login(_pinCtrl.text),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF005C97),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text(
                                  "LOGIN",
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 30),

                const Text(
                  "Powered by Godvel",
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white60,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
