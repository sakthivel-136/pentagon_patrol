import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'home_page.dart';
import 'round_utils.dart';
import 'd1_client.dart';
import 'offline_sync.dart';
import 'models/patrol_round.dart';
import 'app_updater.dart';
import 'shift_utils.dart';
import 'models/shift.dart';
import 'services/time_sync_service.dart';
import 'services/voice_audio_service.dart';

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
  String _selectedVoiceLanguage = 'ta';
  static const String _kCachedUsersKey = 'pentagon_cached_users';

  @override
  void initState() {
    super.initState();

    // 1. Initialize Voice & Audio Confirmation Service
    VoiceAudioService.initialize().then((_) {
      if (mounted) {
        setState(() {
          _selectedVoiceLanguage = VoiceAudioService.currentLanguage;
        });
      }
    });

    // 2. Pre-check Cloudflare Server Time Sync
    TimeSyncService.checkServerTimeDrift();

    Future.delayed(const Duration(milliseconds: 500), () async {
      await _requestNotificationPermission();
      await _scheduleNotifications();
      // Pre-warm local cache of credentials, rounds, and QRs
      _syncBackgroundCache();
      // Check for APK updates silently in the background
      if (mounted) {
        AppUpdater.checkAndPrompt(context, silentIfLatest: true);
      }
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

// ================= CACHE SYNC ==================

  /// Syncs user credentials, factory rounds, and QRs into local storage for offline use.
  Future<void> _syncBackgroundCache() async {
    if (!await _isOnline()) return;

    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Fetch & cache security users and admins
      final usersMap = <String, Map<String, dynamic>>{};

      final admins = await D1Client.query(
        "SELECT name, user_pin, role FROM login_info WHERE is_active = 1",
      );
      for (final a in admins) {
        if (a['user_pin'] != null) {
          usersMap[a['user_pin'].toString().trim()] = {
            'name': a['name'] ?? 'Admin',
            'factory': 'ADMIN',
            'role': a['role'] ?? 'ADMIN',
            'isAdmin': true,
          };
        }
      }

      final guards = await D1Client.query(
        "SELECT security_id, security_name, factory, security_password FROM security_users",
      );
      final factoryCodes = <String>{};
      for (final g in guards) {
        if (g['security_password'] != null) {
          final f = (g['factory'] ?? 'F001').toString().trim();
          factoryCodes.add(f);
          usersMap[g['security_password'].toString().trim()] = {
            'name': g['security_name'] ?? 'Guard',
            'factory': f,
            'role': 'GUARD',
            'isAdmin': false,
            'securityId': (g['security_id'] ?? '').toString().trim(),
          };
        }
      }

      await prefs.setString(_kCachedUsersKey, jsonEncode(usersMap));
      debugPrint("Cached ${usersMap.length} user login profiles locally.");

      // Pre-fetch shifts and guard allocations for each factory
      prefetchShiftsAndAllocations(factoryCodes);

      // 2. Pre-fetch rounds and QR checkpoints for each factory
      for (final fc in factoryCodes) {
        loadRoundsForFactory(fc);
        D1Client.query(
          'SELECT qr_id, qr_name, lat, log, factory_code FROM qr WHERE factory_code = ? AND status = ?',
          [fc, 'active'],
        ).then((qrRows) {
          if (qrRows.isNotEmpty) {
            OfflineSyncManager.cacheCheckpoints(
              fc,
              qrRows.map((e) => Map<String, dynamic>.from(e)).toList(),
            );
          }
        }).catchError((_) {});
      }

      // 3. Flush any pending offline scans from previous runs
      OfflineSyncManager.syncPendingScans();
    } catch (e) {
      debugPrint("Background cache sync error: $e");
    }
  }

  Future<Map<String, dynamic>?> _lookupUser(String pin) async {
    // 1. If online, query D1 directly
    if (await _isOnline()) {
      try {
        final adminList = await D1Client.query(
          "SELECT name, role FROM login_info WHERE user_pin = ? AND is_active = 1 LIMIT 1",
          [pin],
        );
        if (adminList.isNotEmpty) {
          final admin = adminList[0];
          return {
            'name': admin['name'] ?? 'Admin',
            'factory': 'ADMIN',
            'role': admin['role'] ?? 'ADMIN',
            'isAdmin': true,
          };
        }

        final guardList = await D1Client.query(
          "SELECT security_id, security_name, factory FROM security_users WHERE security_password = ? LIMIT 1",
          [pin],
        );
        if (guardList.isNotEmpty) {
          final guard = guardList[0];
          return {
            'name': guard['security_name'] ?? 'Guard',
            'factory': guard['factory'] ?? 'F001',
            'role': 'GUARD',
            'isAdmin': false,
            'securityId': (guard['security_id'] ?? '').toString().trim(),
          };
        }
      } catch (e) {
        debugPrint("Online lookup failed, trying local cache: $e");
      }
    }

    // 2. Fallback to locally cached credentials
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCachedUsersKey);
      if (raw != null && raw.isNotEmpty) {
        final Map<String, dynamic> users = jsonDecode(raw);
        if (users.containsKey(pin)) {
          return Map<String, dynamic>.from(users[pin]);
        }
      }
    } catch (e) {
      debugPrint("Offline user lookup error: $e");
    }

    return null;
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
    final dbRounds = await loadRoundsForFactory('F001');

    for (int i = 0; i < dbRounds.length && i < 33; i++) {
      final r = dbRounds[i];
      final window = resolveWindowInterval(DateTime.now(), r.scanStartTime, r.scanEndTime);
      final timeUtc = window.start.toUtc().subtract(const Duration(minutes: 5));
      final time = tz.TZDateTime.from(timeUtc, tz.local);

      if (time.isBefore(now)) continue;

      await flutterLocalNotificationsPlugin.zonedSchedule(
        i,
        "PATROL ALERT",
        "⏰ Round ${r.roundNumber} starts in 5 minutes (${formatTime12h(r.startTime)})!",
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

// ================= LOGIN & SCAN WINDOW ENFORCEMENT ==================

  Future<void> _login(String pin) async {
    if (pin.length != 4) return;

    setState(() => _loading = true);

    try {
      final user = await _lookupUser(pin);

      if (user == null) {
        _pinCtrl.clear();
        _showMsg("INVALID PIN");
        return;
      }

      final bool isAdmin = user['isAdmin'] == true;
      final String guardName = user['name'] ?? 'Guard';
      final String factoryCode = user['factory'] ?? 'F001';
      final String securityId = (user['securityId'] ?? '').toString().trim();

      // ADMINS can log in at any time
      if (isAdmin) {
        _goHome(guardName, 'ADMIN', true, true);
        return;
      }

      // 0. ANTI-CLOCK MANIPULATION & SERVER TIME DRIFT CHECK
      // If guard changed device clock by > 60 seconds to cheat scan windows, block login!
      final timeCheck = await TimeSyncService.checkServerTimeDrift();
      if (!timeCheck.isSynced) {
        _pinCtrl.clear();
        if (mounted) {
          _showTimeTamperedDialog(
            driftSeconds: timeCheck.driftSeconds,
            serverTime: timeCheck.serverTime,
          );
        }
        return;
      }

      // 1. FOR SECURITY GUARDS: ENFORCE SHIFT ALLOCATION CRITERIA
      // If it is not his shift timing, do not allow him even if scan window is open!
      final shiftCheck = await validateGuardShiftAccess(
        factoryCode: factoryCode,
        securityId: securityId,
      );

      if (!shiftCheck.isAllowed) {
        _pinCtrl.clear();
        if (mounted) {
          _showShiftBlockedDialog(
            guardName: guardName,
            factoryCode: factoryCode,
            activeShift: shiftCheck.activeShift,
            errorMessage: shiftCheck.errorMessage,
          );
        }
        return;
      }

      // 2. ENFORCE FACTORY'S DYNAMIC SCAN WINDOW (Uses accurate server-synchronized time)
      final rounds = await loadRoundsForFactory(factoryCode);
      final status = getFactoryRoundStatus(TimeSyncService.accurateNow, rounds);

      if (status.isScanWindowActive) {
        // Window is OPEN -> allow login into scan interface
        _goHome(guardName, factoryCode, false, true);
      } else {
        // Window is CLOSED -> block login and display live countdown
        _pinCtrl.clear();
        if (mounted) {
          _showScanWindowBlockedDialog(guardName, factoryCode, status, rounds);
        }
      }
    } catch (e) {
      debugPrint("Login error: $e");
      _showMsg("Login Error. Please retry.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

// ================= TIME TAMPERED MODAL ==================

  void _showTimeTamperedDialog({
    required int driftSeconds,
    required DateTime serverTime,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final minutes = (driftSeconds / 60).toStringAsFixed(1);
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Warning Icon
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFFCA5A5), width: 2),
                  ),
                  child: const Icon(
                    Icons.access_time_filled_rounded,
                    color: Color(0xFFDC2626),
                    size: 44,
                  ),
                ),
                const SizedBox(height: 16),

                // Title
                const Text(
                  "DEVICE TIME OUT OF SYNC",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFDC2626),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),

                Text(
                  "நேரம் பொருந்தவில்லை",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 16),

                // Drift Info Container
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        "Time Difference: ~$driftSeconds sec ($minutes mins)",
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF92400E),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "Server Time: ${serverTime.hour.toString().padLeft(2, '0')}:${serverTime.minute.toString().padLeft(2, '0')}:${serverTime.second.toString().padLeft(2, '0')}",
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Color(0xFFB45309),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Instructions in English & Tamil
                const Text(
                  "To prevent timing bypass, please enable 'Set time automatically' or 'Use network-provided time' in your Android Settings.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF475569),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "உங்கள் போன் செட்டிங்ஸில் தானியங்கி நேரத்தை (Automatic Date & Time) ஆன் செய்யவும்.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF475569),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 22),

                // Re-verify Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      final recheck = await TimeSyncService.checkServerTimeDrift();
                      if (!recheck.isSynced && mounted) {
                        _showTimeTamperedDialog(
                          driftSeconds: recheck.driftSeconds,
                          serverTime: recheck.serverTime,
                        );
                      } else {
                        _showMsg("✅ Time synchronized successfully!");
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text(
                      "RE-VERIFY TIME / சரிபார்க்கவும்",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF005C97),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

// ================= SHIFT BLOCKED MODAL ==================

  void _showShiftBlockedDialog({
    required String guardName,
    required String factoryCode,
    DbShift? activeShift,
    String? errorMessage,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final shiftName = activeShift?.shiftName ?? "Active Shift";
        final shiftTimes = activeShift != null
            ? "${formatTime12h(activeShift.startTime)} – ${formatTime12h(activeShift.endTime)}"
            : "";

        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Red/Amber alert badge
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.red.shade200, width: 2),
                  ),
                  child: Icon(
                    Icons.lock_person_rounded,
                    size: 38,
                    color: Colors.red.shade700,
                  ),
                ),
                const SizedBox(height: 16),

                // Title
                const Text(
                  "Shift Access Restricted",
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 6),

                Text(
                  "Security Guard: $guardName\nFactory: $factoryCode",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),

                // Active shift info banner
                if (activeShift != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          "CURRENT ACTIVE SHIFT",
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber.shade400,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          shiftName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        if (shiftTimes.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            shiftTimes,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade300,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // Explanation
                Text(
                  errorMessage ??
                      "You are not assigned to this shift. Guards are only permitted to log in during their allocated shift.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF475569),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),

                // Dismiss Button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF005C97),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      "UNDERSTOOD",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

// ================= SCAN WINDOW BLOCKED MODAL ==================

  void _showScanWindowBlockedDialog(
    String guardName,
    String factoryCode,
    FactoryRoundStatus initialStatus,
    List<DbPatrolRound> rounds,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _ScanWindowBlockedDialog(
          guardName: guardName,
          factoryCode: factoryCode,
          initialStatus: initialStatus,
          rounds: rounds,
          onWindowOpened: () {
            Navigator.of(ctx).pop();
            _goHome(guardName, factoryCode, false, true);
          },
        );
      },
    );
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

                      const SizedBox(height: 16),

                      // VOICE LANGUAGE SELECTOR (குரல் உறுதிப்படுத்தல் மொழி)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: const [
                                    Icon(
                                      Icons.record_voice_over_rounded,
                                      size: 15,
                                      color: Color(0xFF005C97),
                                    ),
                                    SizedBox(width: 5),
                                    Text(
                                      "VOICE LANGUAGE",
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF334155),
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  _selectedVoiceLanguage == 'ta' ? "தமிழ்" : "English",
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF005C97),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                // Tamil Option
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      setState(() => _selectedVoiceLanguage = 'ta');
                                      VoiceAudioService.setLanguage('ta');
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      decoration: BoxDecoration(
                                        color: _selectedVoiceLanguage == 'ta'
                                            ? const Color(0xFF005C97)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: _selectedVoiceLanguage == 'ta'
                                              ? const Color(0xFF005C97)
                                              : const Color(0xFFCBD5E1),
                                        ),
                                        boxShadow: _selectedVoiceLanguage == 'ta'
                                            ? const [
                                                BoxShadow(
                                                  color: Color(0x40005C97),
                                                  blurRadius: 4,
                                                  offset: Offset(0, 2),
                                                )
                                              ]
                                            : const [],
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        "🇮🇳 தமிழ் (Tamil)",
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          color: _selectedVoiceLanguage == 'ta'
                                              ? Colors.white
                                              : const Color(0xFF475569),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // English Option
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      setState(() => _selectedVoiceLanguage = 'en');
                                      VoiceAudioService.setLanguage('en');
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      decoration: BoxDecoration(
                                        color: _selectedVoiceLanguage == 'en'
                                            ? const Color(0xFF005C97)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: _selectedVoiceLanguage == 'en'
                                              ? const Color(0xFF005C97)
                                              : const Color(0xFFCBD5E1),
                                        ),
                                        boxShadow: _selectedVoiceLanguage == 'en'
                                            ? const [
                                                BoxShadow(
                                                  color: Color(0x40005C97),
                                                  blurRadius: 4,
                                                  offset: Offset(0, 2),
                                                )
                                              ]
                                            : const [],
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        "🇬🇧 English",
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          color: _selectedVoiceLanguage == 'en'
                                              ? Colors.white
                                              : const Color(0xFF475569),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

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

                const SizedBox(height: 24),

                GestureDetector(
                  onTap: () {
                    AppUpdater.checkAndPrompt(context, silentIfLatest: false);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Powered by Godvel",
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white60,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.system_update_alt, size: 11, color: Colors.white70),
                            SizedBox(width: 3),
                            Text(
                              "v1.0.0",
                              style: TextStyle(fontSize: 10, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ],
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

// ==============================================================================
// SCAN WINDOW BLOCKED DIALOG WITH LIVE COUNTDOWN
// ==============================================================================

class _ScanWindowBlockedDialog extends StatefulWidget {
  final String guardName;
  final String factoryCode;
  final FactoryRoundStatus initialStatus;
  final List<DbPatrolRound> rounds;
  final VoidCallback onWindowOpened;

  const _ScanWindowBlockedDialog({
    required this.guardName,
    required this.factoryCode,
    required this.initialStatus,
    required this.rounds,
    required this.onWindowOpened,
  });

  @override
  State<_ScanWindowBlockedDialog> createState() => _ScanWindowBlockedDialogState();
}

class _ScanWindowBlockedDialogState extends State<_ScanWindowBlockedDialog> {
  Timer? _countdownTimer;
  late FactoryRoundStatus _status;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final updatedStatus = getFactoryRoundStatus(now, widget.rounds);

      if (updatedStatus.isScanWindowActive) {
        _countdownTimer?.cancel();
        widget.onWindowOpened();
      } else {
        if (mounted) {
          setState(() {
            _status = updatedStatus;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration? d) {
    if (d == null) return "soon";
    final totalSec = d.inSeconds;
    if (totalSec <= 0) return "opening now";
    final hours = totalSec ~/ 3600;
    final minutes = (totalSec % 3600) ~/ 60;
    final seconds = totalSec % 60;

    if (hours > 0) {
      return "${hours}h ${minutes}m ${seconds.toString().padLeft(2, '0')}s";
    }
    return "${minutes}m ${seconds.toString().padLeft(2, '0')}s";
  }

  @override
  Widget build(BuildContext context) {
    final nextRound = _status.nextRound;
    final countdownStr = _formatDuration(_status.timeUntilNextWindow);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.amber.shade200, width: 2),
              ),
              child: Icon(
                Icons.lock_clock,
                size: 38,
                color: Colors.amber.shade800,
              ),
            ),
            const SizedBox(height: 16),

            // Title
            const Text(
              "Login Window Closed",
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 6),

            Text(
              "Security Guard: ${widget.guardName}\nFactory: ${widget.factoryCode}",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),

            // Live Countdown Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                children: [
                  const Text(
                    "NEXT PATROL SCAN WINDOW",
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (nextRound != null) ...[
                    Text(
                      "Round ${nextRound.roundNumber.toString().padLeft(2, '0')}",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF005C97),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Window: ${formatTime12h(nextRound.scanStartTime)} – ${formatTime12h(nextRound.scanEndTime)}",
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      "Opens in: $countdownStr",
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),
            Text(
              "Guards can only log into VeriPatrol when their factory's scan window is open.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 18),

            // Close button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF005C97),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text(
                  "OK",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
