import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../d1_client.dart';

class TimeSyncResult {
  final bool isSynced;
  final int driftSeconds;
  final DateTime serverTime;
  final String? errorMessage;

  TimeSyncResult({
    required this.isSynced,
    required this.driftSeconds,
    required this.serverTime,
    this.errorMessage,
  });
}

class TimeSyncService {
  static const int maxAllowedDriftSeconds = 60;
  static int _serverOffsetSeconds = 0;
  static bool _hasSynced = false;

  /// Returns current time adjusted with server offset
  static DateTime get accurateNow {
    return DateTime.now().toUtc().add(Duration(seconds: _serverOffsetSeconds)).toLocal();
  }

  static bool get hasSynced => _hasSynced;
  static int get serverOffsetSeconds => _serverOffsetSeconds;

  /// Fetches real UTC server time from Cloudflare edge and compares with device time.
  static Future<TimeSyncResult> checkServerTimeDrift() async {
    final clientUtc = DateTime.now().toUtc();
    DateTime? serverUtc;

    try {
      // 1. Send HEAD request to Cloudflare edge worker (fastest, lightweight)
      final headResponse = await http.head(
        Uri.parse(D1Client.baseUrl),
      ).timeout(const Duration(seconds: 5));

      final dateHeader = headResponse.headers['date'];
      if (dateHeader != null && dateHeader.isNotEmpty) {
        try {
          serverUtc = HttpDate.parse(dateHeader).toUtc();
        } catch (_) {}
      }

      // 2. Fallback to SQL query if header not parsed
      if (serverUtc == null) {
        final rows = await D1Client.query("SELECT CURRENT_TIMESTAMP as now;");
        if (rows.isNotEmpty && rows[0]['now'] != null) {
          final str = rows[0]['now'].toString();
          // SQLite CURRENT_TIMESTAMP format is 'YYYY-MM-DD HH:MM:SS' UTC
          serverUtc = DateTime.parse('${str.replaceFirst(' ', 'T')}Z').toUtc();
        }
      }
    } catch (e) {
      debugPrint("Time sync check network error: $e");
    }

    if (serverUtc == null) {
      // If network is down, assume synced if previously verified, otherwise allow offline grace
      return TimeSyncResult(
        isSynced: true,
        driftSeconds: _serverOffsetSeconds,
        serverTime: accurateNow,
        errorMessage: "Offline: using last synced server offset",
      );
    }

    final diffSeconds = (clientUtc.difference(serverUtc).inSeconds);
    final absDrift = diffSeconds.abs();

    _serverOffsetSeconds = -diffSeconds;
    _hasSynced = true;

    final isSynced = absDrift <= maxAllowedDriftSeconds;

    return TimeSyncResult(
      isSynced: isSynced,
      driftSeconds: absDrift,
      serverTime: serverUtc.toLocal(),
      errorMessage: isSynced
          ? null
          : "Device clock differs by $absDrift seconds (limit: $maxAllowedDriftSeconds s).",
    );
  }
}
