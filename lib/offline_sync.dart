// lib/offline_sync.dart
// Offline Scan Queue and Cache Manager for Pentagon Patrol.
// Handles local caching of QR checkpoints, offline queueing of guard scans,
// and automatic background synchronization when mobile connectivity is restored.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'd1_client.dart';

class OfflineSyncManager {
  static const String _kOfflineQueueKey = 'pentagon_offline_scans_queue';
  static const String _kQrCachePrefix = 'pentagon_cached_qr_';

  /// Saves the active checkpoints list for a specific factory for offline availability.
  static Future<void> cacheCheckpoints(
    String factoryCode,
    List<Map<String, dynamic>> checkpoints,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_kQrCachePrefix$factoryCode';
      final jsonStr = jsonEncode(checkpoints);
      await prefs.setString(key, jsonStr);
    } catch (e) {
      debugPrint('Error caching checkpoints: $e');
    }
  }

  /// Loads cached checkpoints for a factory when device is offline.
  static Future<List<Map<String, dynamic>>> getCachedCheckpoints(
    String factoryCode,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_kQrCachePrefix$factoryCode';
      final jsonStr = prefs.getString(key);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error loading cached checkpoints: $e');
    }
    return [];
  }

  /// Queues an offline scan when there is no internet connection.
  /// Preserves the exact scan timestamp, GPS coordinates, and round slot.
  static Future<void> queueOfflineScan(Map<String, dynamic> scanData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<Map<String, dynamic>> currentQueue = await getOfflineScans();

      // Avoid duplicates in the offline queue
      final isDuplicate = currentQueue.any((item) =>
          item['qr_id'].toString() == scanData['qr_id'].toString() &&
          item['round_slot'] == scanData['round_slot'] &&
          item['factory_code'] == scanData['factory_code']);

      if (!isDuplicate) {
        currentQueue.add(scanData);
        await prefs.setString(_kOfflineQueueKey, jsonEncode(currentQueue));
        debugPrint('Queued offline scan for QR ${scanData['qr_id']}. Total in queue: ${currentQueue.length}');
      }
    } catch (e) {
      debugPrint('Error queueing offline scan: $e');
    }
  }

  /// Retrieves all pending offline scans.
  static Future<List<Map<String, dynamic>>> getOfflineScans() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kOfflineQueueKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (e) {
      debugPrint('Error getting offline scans: $e');
    }
    return [];
  }

  /// Returns the set of QR IDs that were scanned offline for the given factory and round slot.
  static Future<Set<String>> getOfflineScannedQrIds(
    String factoryCode,
    String roundSlot,
  ) async {
    final queue = await getOfflineScans();
    final Set<String> qrIds = {};
    for (var item in queue) {
      if (item['factory_code'] == factoryCode &&
          item['round_slot'] == roundSlot &&
          item['status'] == 'SUCCESS') {
        qrIds.add(item['qr_id'].toString().trim());
      }
    }
    return qrIds;
  }

  /// Flushes all pending offline scans to Cloudflare D1 database.
  /// Returns the count of successfully synced scans.
  static Future<int> syncPendingScans() async {
    final queue = await getOfflineScans();
    if (queue.isEmpty) return 0;

    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      debugPrint('Sync aborted: device still offline');
      return 0;
    }

    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> remainingQueue = [];
    int successCount = 0;

    for (var scan in queue) {
      try {
        await D1Client.query(
          'INSERT INTO scanning_details (guard_name, qr_id, qr_name, lat, log, factory_code, scan_time, round_slot, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            scan['guard_name'],
            scan['qr_id'].toString(),
            scan['qr_name'] ?? '',
            scan['lat'] ?? 0.0,
            scan['log'] ?? 0.0,
            scan['factory_code'],
            scan['scan_time'], // Preserves the exact offline timestamp
            scan['round_slot'],
            scan['status'] ?? 'SUCCESS',
          ],
        );
        successCount++;
        debugPrint('Successfully synced offline scan for QR ${scan['qr_id']}');
      } catch (e) {
        final msg = e.toString();
        // If it was already inserted by a parallel device, treat as resolved
        if (msg.contains('23505') || msg.contains('UNIQUE constraint failed')) {
          successCount++;
          debugPrint('Offline scan for QR ${scan['qr_id']} was already in database');
        } else {
          debugPrint('Failed to sync offline scan for QR ${scan['qr_id']}: $e');
          remainingQueue.add(scan);
        }
      }
    }

    await prefs.setString(_kOfflineQueueKey, jsonEncode(remainingQueue));
    return successCount;
  }
}
