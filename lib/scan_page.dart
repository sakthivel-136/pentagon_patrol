// scan_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'd1_client.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'round_utils.dart';

class ScanningPage extends StatefulWidget {
  final String guardName;
  final String factoryCode;
  final bool isMaster;

  const ScanningPage({
    super.key,
    required this.guardName,
    required this.factoryCode,
    required this.isMaster,
  });

  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> {
  final MobileScannerController scannerController = MobileScannerController();

  List<Map<String, dynamic>> _checkpoints = [];

  bool _loading = true;
  bool _isProcessing = false;

  String? _activeQrId;

  int _overlayTimer = 0;
  int _totalTime = 0;

  bool _torchOn = false;
  bool _torchReady = false;

  late DateTime _currentRound;
  String _currentRoundLabel = '';
  DateTime? _currentWindowStart;
  DateTime? _currentWindowEnd;
  bool _scanAvailable = false;
  bool _showingCompleteDialog = false;

  Timer? _syncTimer;

  DateTime? _lastScanTime; // cooldown

  // ================= INIT =================

  @override
  void initState() {
    super.initState();

    _currentRound = _getRoundStart();

    final h = DateTime.now().hour;
    _torchOn = (h >= 18 || h < 6);

    _initScanner();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestRequiredPermissions();
    });
    _fetchCheckpoints();

    _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _fetchCheckpoints();
    });
  }

  // ================= SLOT =================

  DateTime _getRoundStart() {
    return getNearestPatrolRoundStart(DateTime.now());
  }

  bool _isValidTime() {
    final now = DateTime.now();

    final start = _currentRound;
    return isWithinPatrolScanWindow(now, start);
  }

  String _windowLabel() {
    if (_currentWindowStart == null || _currentWindowEnd == null) {
      return '';
    }
    return "${DateFormat('hh:mm a').format(_currentWindowStart!)} - ${DateFormat('hh:mm a').format(_currentWindowEnd!)}";
  }

  // ================= SCANNER =================

  void _initScanner() async {
    await Future.delayed(const Duration(milliseconds: 800));

    try {
      _torchReady = true;

      if (_torchOn) {
        await scannerController.toggleTorch();
      }
    } catch (_) {}
  }

  String _norm(dynamic v) {
    if (v == null) return '';
    String s = v.toString().trim().replaceAll(' ', '');
    if (s.endsWith('.0')) {
      s = s.substring(0, s.length - 2);
    }
    return s;
  }

  // ================= FETCH =================

  Future<void> _fetchCheckpoints() async {
    try {
      final now = DateTime.now();
      final roundInfo = getCurrentPatrolRound(now);
      _currentRound = roundInfo['currentRoundTime'] as DateTime;
      _currentRoundLabel = roundInfo['currentRoundLabel'] as String;
      _currentWindowStart = roundInfo['scanWindowOpen'] as DateTime;
      _currentWindowEnd = roundInfo['scanWindowClose'] as DateTime;
      _scanAvailable = roundInfo['isActive'] as bool;
      final qrData = await D1Client
          .query('SELECT * FROM qr WHERE factory_code = ? AND status = ?', [widget.factoryCode, 'active']);

      final scanData = await D1Client
          .query('SELECT qr_id, status FROM scanning_details WHERE factory_code = ? AND round_slot = ?', [widget.factoryCode, _currentRound.toUtc().toIso8601String()]);

      final Set<String> success = {};

      for (var e in scanData) {
        if (e['status'] == 'SUCCESS') {
          success.add(_norm(e['qr_id']));
        }
      }

      if (!mounted) return;

      setState(() {
        _checkpoints = qrData.map((e) {
          final id = _norm(e['qr_id']);
          final previous = _checkpoints.firstWhere(
            (old) => _norm(old['qr_id']) == id,
            orElse: () => {},
          );

          return {
            ...e,
            'completed': success.contains(id),
            'scanned_once': previous['scanned_once'] ?? false,
            'waiting_done': previous['waiting_done'] ?? false,
            'timer': previous['timer'] ?? 0,
            'start_time': previous['start_time'],
            'waiting_time': e['waiting_time'] ?? 15,
          };
        }).map((e) => Map<String, dynamic>.from(e)).toList();

        _loading = false;
      });

      _checkAutoLogout();
    } catch (e) {
      debugPrint("Fetch error: $e");
    }
  }

  // ================= DB CHECK =================

  Future<bool> _existsSuccess(String qr) async {
    try {
      final resList = await D1Client
          .query('SELECT id FROM scanning_details WHERE factory_code = ? AND qr_id = ? AND round_slot = ? AND status = ? LIMIT 1',
                 [widget.factoryCode, qr, _currentRound.toUtc().toIso8601String(), 'SUCCESS']);
      final res = resList.isNotEmpty ? resList[0] : null;

      if (res != null) {
        debugPrint("ExistsSuccess true: ${res['id']}");
      }
      return res != null;
    } catch (e) {
      debugPrint("ExistsSuccess error: $e");
      return false;
    }
  }

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<Position?> _getCurrentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      return position;
    } catch (e) {
      debugPrint('High accuracy location failed, trying low accuracy: $e');
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 5),
        );
        return position;
      } catch (e2) {
        debugPrint('Location fetch failed: $e2, using fallback');
        return null;
      }
    }
  }

  Future<void> _requestRequiredPermissions() async {
    final cameraGranted = await _requestPermission(
      Permission.camera,
      'Camera',
    );

    final locationGranted = await _requestPermission(
      Permission.locationWhenInUse,
      'Location',
    );

    final notificationGranted = await _requestPermission(
      Permission.notification,
      'Notifications',
    );

    if (!cameraGranted) {
      _msg('Camera permission required for scanning.', Colors.red);
    }

    if (!locationGranted) {
      _msg('Location permission required for scan upload.', Colors.red);
    }

    if (!notificationGranted) {
      _msg('Notification permission required for alerts.', Colors.orange);
    }
  }

  Future<bool> _requestPermission(
    Permission permission,
    String permissionName,
  ) async {
    var status = await permission.status;
    if (status.isGranted) return true;

    if (status.isDenied || status.isRestricted) {
      status = await permission.request();
    }

    if (status.isGranted) return true;

    if (status.isPermanentlyDenied) {
      _msg(
          '$permissionName permission blocked. Open app settings.', Colors.red);
    } else {
      _msg('$permissionName permission denied.', Colors.red);
    }

    return status.isGranted;
  }

  // ================= MESSAGE =================

  void _msg(String m, Color c) {
    HapticFeedback.vibrate();

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: c,
        content: Text(
          m,
          style:
              const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
    );
  }

  // ================= AUTO LOGOUT =================

  void _checkAutoLogout() {
    if (_checkpoints.isEmpty) return;

    final done = _checkpoints.every((e) => e['completed'] == true);

    if (done) {
      if (!_showingCompleteDialog) {
        _showingCompleteDialog = true;
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return const AlertDialog(
              title: Text("Scan Completed"),
              content: Text(
                  "All checkpoints are complete. Returning to home..."),
            );
          },
        );
        Future.delayed(const Duration(seconds: 4), () {
          if (!mounted) return;
          Navigator.of(context).pop();
          Navigator.of(context).pop();
          _showingCompleteDialog = false;
        });
      }
    }
  }

  // ================= SCAN =================

  Future<void> _onScan(BarcodeCapture capture) async {
    // Cooldown (prevents spam)
    final now = DateTime.now();
    _currentRound = _getRoundStart();

    if (_lastScanTime != null && now.difference(_lastScanTime!).inSeconds < 2) {
      return;
    }

    _lastScanTime = now;

    if (_isProcessing) return;

    final raw = capture.barcodes.first.rawValue ?? '';
    final qrId = _norm(raw);

    if (qrId.isEmpty) return;

    final index = _checkpoints.indexWhere((p) => _norm(p['qr_id']) == qrId);

    if (index == -1) {
      _msg("UNKNOWN QR", Colors.orange);
      return;
    }

    final p = _checkpoints[index];

    // Already finished
    if (p['completed'] == true) {
      _msg("ALREADY SCANNED", Colors.green);
      return;
    }

    // One at a time lock
    if (_activeQrId != null && _activeQrId != qrId) {
      _msg("FINISH CURRENT QR", Colors.red);
      return;
    }

    final valid = widget.isMaster || _isValidTime();

    if (!valid) {
      _msg("OUTSIDE SCAN WINDOW", Colors.red);
      return;
    }

    // ---------- FIRST SCAN ----------
    if (p['scanned_once'] == true && p['waiting_done'] == false) {
      final remaining = p['timer'] ?? 0;
      _msg("WAIT ${remaining}s", Colors.orange);
      return;
    }

    if (!p['scanned_once'] && p['waiting_done'] == false) {
      if (await _existsSuccess(qrId)) {
        _msg("ALREADY SCANNED", Colors.green);
        _fetchCheckpoints();
        return;
      }

      _startTimer(index);
      return;
    }

    // ---------- SECOND SCAN ----------
    if (p['waiting_done'] == true) {
      if (await _existsSuccess(qrId)) {
        _msg("ALREADY SCANNED", Colors.green);
        _fetchCheckpoints();
        return;
      }

      await _saveSuccess(p);
    }
  }

  // ================= SAVE SUCCESS =================

  Future<void> _saveSuccess(Map p) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      if (!await _isOnline()) {
        _msg('NO INTERNET', Colors.red);
        return;
      }

      var pos = await _getCurrentPosition();
      if (pos == null) {
        _msg('CANNOT GET LOCATION - SCAN FAILED', Colors.red);
        return;
      }

      await D1Client.query(
        'INSERT INTO scanning_details (guard_name, qr_id, qr_name, lat, log, factory_code, scan_time, round_slot, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          widget.guardName,
          p['qr_id'].toString(),
          p['qr_name'],
          pos.latitude,
          pos.longitude,
          widget.factoryCode,
          DateTime.now().toUtc().toIso8601String(),
          _currentRound.toUtc().toIso8601String(),
          'SUCCESS'
        ],
      );

      _activeQrId = null;
      _msg('SCAN UPLOADED', Colors.green);

      _fetchCheckpoints();
      _checkAutoLogout();
    } catch (e) {
      final msg = e.toString();

      if (msg.contains('23505') || msg.contains('UNIQUE constraint failed')) {
        _msg("ALREADY SCANNED", Colors.green);
        _fetchCheckpoints();
      } else {
        debugPrint("Save error: $e");
        _msg("UPLOAD FAILED", Colors.red);
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      } else {
        _isProcessing = false;
      }
    }
  }

  // ================= SAVE MISSED =================

  Future<void> _saveMissed(Map p) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      if (!await _isOnline()) {
        _msg('NO INTERNET', Colors.red);
        return;
      }

      var pos = await _getCurrentPosition();
      if (pos == null) {
        _msg('CANNOT GET LOCATION - SCAN FAILED', Colors.red);
        return;
      }

      await D1Client.query(
        'INSERT INTO scanning_details (guard_name, qr_id, qr_name, lat, log, factory_code, scan_time, round_slot, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          widget.guardName,
          p['qr_id'].toString(),
          p['qr_name'],
          pos.latitude,
          pos.longitude,
          widget.factoryCode,
          DateTime.now().toUtc().toIso8601String(),
          _currentRound.toUtc().toIso8601String(),
          'MISSED'
        ],
      );

      _fetchCheckpoints();
      _msg("MARKED MISSED", Colors.red);
    } catch (e) {
      debugPrint("Missed error: $e");
      _msg("UPLOAD FAILED", Colors.red);
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      } else {
        _isProcessing = false;
      }
    }
  }

  // ================= TIMER =================

  void _startTimer(int index) {
    final p = _checkpoints[index];

    setState(() {
      _activeQrId = _norm(p['qr_id']);

      p['scanned_once'] = true;
      p['waiting_done'] = false;

      p['start_time'] = DateTime.now();

      p['timer'] = p['waiting_time'];

      _totalTime = p['waiting_time'];
      _overlayTimer = p['waiting_time'];
    });

    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();

      final remain = p['waiting_time'] -
          DateTime.now().difference(p['start_time']).inSeconds;

      if (remain <= 0) {
        t.cancel();

        setState(() {
          p['timer'] = 0;
          _overlayTimer = 0;

          p['waiting_done'] = true;

          // ❗ DO NOT CLEAR activeQrId HERE
        });

        HapticFeedback.vibrate();
      } else {
        setState(() {
          p['timer'] = remain;
          _overlayTimer = remain;
        });
      }
    });
  }

  // ================= FLASH =================

  void _toggleFlash() async {
    if (!_torchReady) return;

    try {
      await scannerController.toggleTorch();
      setState(() => _torchOn = !_torchOn);
    } catch (_) {}
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF005C97),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("QR Patrol Scan"),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggleFlash,
        backgroundColor: _torchOn ? Colors.yellow : Colors.white24,
        child: Icon(
          _torchOn ? Icons.flash_on : Icons.flash_off,
          color: _torchOn ? Colors.black : Colors.white,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Column(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _currentRoundLabel.isEmpty
                              ? 'Current Scan'
                              : _currentRoundLabel,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF005C97),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _windowLabel(),
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _scanAvailable
                              ? 'SCAN WINDOW OPEN'
                              : 'WAITING FOR SCAN WINDOW',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _scanAvailable ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // CAMERA
                SizedBox(
                  height: 200,
                  width: 200,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      children: [
                        MobileScanner(
                          controller: scannerController,
                          onDetect: _onScan,
                        ),
                        if (_overlayTimer > 0)
                          Positioned.fill(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text(
                                  "$_overlayTimer",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 36,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: LinearProgressIndicator(
                                    value: _overlayTimer / _totalTime,
                                    backgroundColor: Colors.white24,
                                    valueColor: const AlwaysStoppedAnimation(
                                        Colors.yellow),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // LIST
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    itemCount: _checkpoints.length,
                    itemBuilder: (_, i) {
                      final p = _checkpoints[i];
                      final bool completed = p['completed'] == true;
                      final bool waitingDone = p['waiting_done'] == true;
                      final bool scannedOnce = p['scanned_once'] == true;
                      Color bg;
                      Color txt;
                      String statusLabel;
                      if (completed) {
                        bg = Colors.green.shade600;
                        txt = Colors.white;
                        statusLabel = 'Completed';
                      } else if (waitingDone) {
                        bg = Colors.amber.shade600;
                        txt = Colors.black87;
                        statusLabel = 'Ready for final scan';
                      } else if (scannedOnce) {
                        bg = Colors.amber.shade600;
                        txt = Colors.black87;
                        statusLabel = 'First scan registered';
                      } else {
                        bg = Colors.white;
                        txt = Colors.black87;
                        statusLabel = 'Tap once to start';
                      }
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    p['qr_name'] ?? "POINT ${i + 1}",
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: txt,
                                    ),
                                  ),
                                ),
                                if (completed)
                                  const Icon(Icons.check_circle,
                                      color: Colors.white)
                                else if (waitingDone)
                                  const Icon(Icons.play_arrow,
                                      color: Colors.black)
                                else if (scannedOnce)
                                  const Icon(Icons.stop_circle,
                                      color: Colors.white)
                                else
                                  Icon(
                                    Icons.radio_button_unchecked,
                                    color: Colors.grey.shade400,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              statusLabel,
                              style: TextStyle(
                                fontSize: 13,
                                color: txt,
                              ),
                            ),
                            if (p['timer'] > 0) ...[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "WAIT ${p['timer']}s",
                                    style: TextStyle(
                                      color: txt,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 100,
                                    child: LinearProgressIndicator(
                                      value: p['timer'] /
                                          (p['waiting_time'] ?? 15),
                                      backgroundColor: Colors.white24,
                                      valueColor: AlwaysStoppedAnimation(txt),
                                    ),
                                  ),
                                ],
                              ),
                            ]
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  // ================= DISPOSE =================

  @override
  void dispose() {
    _syncTimer?.cancel();
    scannerController.dispose();
    super.dispose();
  }
}
