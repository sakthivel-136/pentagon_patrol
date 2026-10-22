// lib/round_utils.dart
// 100% Database-Driven Patrol Rounds & Scan Window Engine.
// Takes all round details strictly from the Cloudflare D1 database.
// NO hardcoded / fixed fallback rounds. If unconfigured, leaves empty.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/patrol_round.dart';
import 'd1_client.dart';

class PatrolRound {
  final DateTime time;
  final String label;
  final int round;
  final DateTime? scanWindowOpen;
  final DateTime? scanWindowClose;

  PatrolRound(
    this.time,
    this.label,
    this.round, {
    this.scanWindowOpen,
    this.scanWindowClose,
  });
}

String _twoDigit(int n) => n.toString().padLeft(2, '0');

/// Converts a 24h "HH:mm" time string into a 12h "hh:mm a" string
String formatTime12h(String hhmm) {
  try {
    final parts = hhmm.split(':');
    final hour = int.parse(parts[0]);
    final minute = parts[1];
    final ampm = hour >= 12 ? 'PM' : 'AM';
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '${_twoDigit(h12)}:$minute $ampm';
  } catch (_) {
    return hhmm;
  }
}

// ==============================================================================
// TIME INTERVAL RESOLVER (HANDLES OVERNIGHT / MIDNIGHT CROSSOVER)
// ==============================================================================

class WindowInterval {
  final DateTime start;
  final DateTime end;
  WindowInterval(this.start, this.end);
}

/// Resolves the exact absolute DateTime start and end for a "HH:mm" - "HH:mm" interval
/// relative to [now], correctly handling overnight slots that cross midnight.
WindowInterval resolveWindowInterval(DateTime now, String startHhmm, String endHhmm) {
  try {
    final sParts = startHhmm.split(':').map(int.parse).toList();
    final eParts = endHhmm.split(':').map(int.parse).toList();

    final sMinutes = sParts[0] * 60 + sParts[1];
    final eMinutes = eParts[0] * 60 + eParts[1];

    int durationMinutes = eMinutes - sMinutes;
    if (durationMinutes <= 0) {
      durationMinutes += 24 * 60; // Crosses midnight
    }

    // Interval candidate starting today
    final todayStart = DateTime(now.year, now.month, now.day, sParts[0], sParts[1]);
    final todayEnd = todayStart.add(Duration(minutes: durationMinutes));

    // If now is currently inside today's interval
    if (!now.isBefore(todayStart) && now.isBefore(todayEnd)) {
      return WindowInterval(todayStart, todayEnd);
    }

    // Interval candidate starting yesterday (for post-midnight spillover)
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final yesterdayEnd = yesterdayStart.add(Duration(minutes: durationMinutes));
    if (!now.isBefore(yesterdayStart) && now.isBefore(yesterdayEnd)) {
      return WindowInterval(yesterdayStart, yesterdayEnd);
    }

    // If today's interval has already passed, candidate is tomorrow
    if (now.isAfter(todayEnd)) {
      final tomorrowStart = todayStart.add(const Duration(days: 1));
      final tomorrowEnd = tomorrowStart.add(Duration(minutes: durationMinutes));
      return WindowInterval(tomorrowStart, tomorrowEnd);
    }

    return WindowInterval(todayStart, todayEnd);
  } catch (e) {
    debugPrint("resolveWindowInterval error: $e");
    return WindowInterval(now, now.add(const Duration(hours: 1)));
  }
}

// ==============================================================================
// STRICT DATABASE-DRIVEN PATROL ROUNDS LOADER & CACHE
// ==============================================================================

String _cacheKey(String factoryCode) => 'pentagon_cached_rounds_$factoryCode';

/// Loads rounds for a specific factory strictly from the Cloudflare D1 database.
/// If network is offline, loads from local cached snapshot.
/// If no rounds are configured in database, returns [] (EMPTY). ZERO synthetic fallbacks.
Future<List<DbPatrolRound>> loadRoundsForFactory(String factoryCode) async {
  final resolvedFactory = (factoryCode.isEmpty || factoryCode == 'ADMIN') ? 'F001' : factoryCode;

  try {
    // 1. Attempt Cloudflare D1 query
    final rows = await D1Client.query(
      'SELECT id, factory_code, round_number, start_time, end_time, scan_start_time, scan_end_time '
      'FROM rounds WHERE factory_code = ? ORDER BY round_number ASC',
      [resolvedFactory],
    ).timeout(const Duration(seconds: 8));

    if (rows.isNotEmpty) {
      final rounds = rows
          .map((r) => DbPatrolRound.fromJson(Map<String, dynamic>.from(r)))
          .toList()
        ..sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
      // Update local cache
      await saveCachedRounds(resolvedFactory, rounds);
      debugPrint("Loaded ${rounds.length} rounds from D1 for factory $resolvedFactory");
      return rounds;
    }
  } catch (e) {
    debugPrint("Failed to fetch rounds from D1 for $resolvedFactory, falling back to cache: $e");
  }

  // 2. Fallback to cached rounds snapshot
  final cached = await getCachedRounds(resolvedFactory);
  if (cached.isNotEmpty) {
    debugPrint("Loaded ${cached.length} cached rounds for factory $resolvedFactory");
    return cached;
  }

  // 3. No rounds configured in database: return EMPTY list
  debugPrint("No rounds configured in database for factory $resolvedFactory");
  return <DbPatrolRound>[];
}

/// Retrieves locally stored rounds from SharedPreferences for [factoryCode].
Future<List<DbPatrolRound>> getCachedRounds(String factoryCode) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_cacheKey(factoryCode));
    if (jsonStr != null && jsonStr.isNotEmpty) {
      final List<dynamic> raw = json.decode(jsonStr);
      return raw
          .map((e) => DbPatrolRound.fromJson(Map<String, dynamic>.from(e)))
          .toList()
        ..sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
    }
  } catch (e) {
    debugPrint("Error reading cached rounds: $e");
  }
  return [];
}

/// Caches rounds in SharedPreferences.
Future<void> saveCachedRounds(String factoryCode, List<DbPatrolRound> rounds) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = json.encode(rounds.map((r) => r.toJson()).toList());
    await prefs.setString(_cacheKey(factoryCode), jsonStr);
  } catch (e) {
    debugPrint("Error saving rounds to cache: $e");
  }
}

// ==============================================================================
// FACTORY ROUND STATUS & ENFORCEMENT ENGINE
// ==============================================================================

class FactoryRoundStatus {
  final bool isScanWindowActive;
  final DbPatrolRound? activeRound;
  final DateTime? activeWindowStart;
  final DateTime? activeWindowEnd;
  final DbPatrolRound? nextRound;
  final DateTime? nextWindowStart;
  final Duration? timeUntilNextWindow;
  final Duration? remainingWindowTime;
  final String formattedLabel;
  final String formattedScanWindow;

  FactoryRoundStatus({
    required this.isScanWindowActive,
    required this.activeRound,
    required this.activeWindowStart,
    required this.activeWindowEnd,
    required this.nextRound,
    required this.nextWindowStart,
    required this.timeUntilNextWindow,
    required this.remainingWindowTime,
    required this.formattedLabel,
    required this.formattedScanWindow,
  });
}

/// Analyzes [now] against the configured database [rounds] for a factory to determine:
/// - If a scan window is currently open (guard login allowed)
/// - The active round and exact scan window from database scan_start_time / scan_end_time
/// - The next scheduled scan window
FactoryRoundStatus getFactoryRoundStatus(DateTime now, List<DbPatrolRound> rounds) {
  if (rounds.isEmpty) {
    return FactoryRoundStatus(
      isScanWindowActive: true, // Allow login if factory has no rounds configured
      activeRound: null,
      activeWindowStart: null,
      activeWindowEnd: null,
      nextRound: null,
      nextWindowStart: null,
      timeUntilNextWindow: null,
      remainingWindowTime: null,
      formattedLabel: "No Rounds Configured",
      formattedScanWindow: "",
    );
  }

  DbPatrolRound? activeRound;
  DateTime? activeWindowStart;
  DateTime? activeWindowEnd;
  Duration? remainingWindow;

  DbPatrolRound? nextRound;
  DateTime? nextWindowStart;
  Duration? untilNext;

  // 1. Check if now falls inside ANY round's database-configured scan window
  for (final r in rounds) {
    final interval = resolveWindowInterval(now, r.scanStartTime, r.scanEndTime);
    if (!now.isBefore(interval.start) && now.isBefore(interval.end)) {
      activeRound = r;
      activeWindowStart = interval.start;
      activeWindowEnd = interval.end;
      remainingWindow = interval.end.difference(now);
      break;
    }
  }

  // 2. Find the next scan window opening in the future
  DateTime? closestFutureStart;
  DbPatrolRound? closestRound;

  for (final r in rounds) {
    final interval = resolveWindowInterval(now, r.scanStartTime, r.scanEndTime);
    if (interval.start.isAfter(now)) {
      if (closestFutureStart == null || interval.start.isBefore(closestFutureStart)) {
        closestFutureStart = interval.start;
        closestRound = r;
      }
    }
  }

  // If no future window found today, wrap around to tomorrow's first round
  if (closestFutureStart == null) {
    final first = rounds.first;
    final interval = resolveWindowInterval(now, first.scanStartTime, first.scanEndTime);
    final tomorrowStart = interval.start.add(const Duration(days: 1));
    closestFutureStart = tomorrowStart;
    closestRound = first;
  }

  nextRound = closestRound;
  nextWindowStart = closestFutureStart;
  untilNext = closestFutureStart.difference(now);

  String label = '';
  String scanWindow = '';
  if (activeRound != null && activeWindowStart != null && activeWindowEnd != null) {
    final start12 = formatTime12h(activeRound.startTime);
    final end12 = formatTime12h(activeRound.endTime);
    label = 'Round ${_twoDigit(activeRound.roundNumber)} ($start12 – $end12)';

    final scanStart12 = formatTime12h(activeRound.scanStartTime);
    final scanEnd12 = formatTime12h(activeRound.scanEndTime);
    scanWindow = '$scanStart12 – $scanEnd12';
  } else if (nextRound != null) {
    label = 'Next: Round ${_twoDigit(nextRound.roundNumber)} (${formatTime12h(nextRound.startTime)})';
    scanWindow = 'Opens at ${formatTime12h(nextRound.scanStartTime)}';
  }

  return FactoryRoundStatus(
    isScanWindowActive: activeRound != null,
    activeRound: activeRound,
    activeWindowStart: activeWindowStart,
    activeWindowEnd: activeWindowEnd,
    nextRound: nextRound,
    nextWindowStart: nextWindowStart,
    timeUntilNextWindow: untilNext,
    remainingWindowTime: remainingWindow,
    formattedLabel: label,
    formattedScanWindow: scanWindow,
  );
}

// ==============================================================================
// CURRENT PATROL ROUND LOOKUP (DATABASE-ONLY)
// ==============================================================================

Map<String, dynamic> getCurrentPatrolRound(DateTime now, {List<DbPatrolRound>? dbRounds}) {
  if (dbRounds == null || dbRounds.isEmpty) {
    return {
      'current': null,
      'next': null,
      'currentRoundTime': now,
      'nextRoundTime': now,
      'currentRoundLabel': 'No rounds configured',
      'currentRoundNumber': 0,
      'scanWindowOpen': null,
      'scanWindowClose': null,
      'isActive': false,
    };
  }

  final status = getFactoryRoundStatus(now, dbRounds);
  final active = status.activeRound ?? dbRounds.first;
  final next = status.nextRound ?? (dbRounds.length > 1 ? dbRounds[1] : dbRounds.first);

  final activeWindow = status.activeWindowStart != null && status.activeWindowEnd != null
      ? WindowInterval(status.activeWindowStart!, status.activeWindowEnd!)
      : resolveWindowInterval(now, active.scanStartTime, active.scanEndTime);

  final nextWindow = resolveWindowInterval(now, next.scanStartTime, next.scanEndTime);
  final roundInterval = resolveWindowInterval(now, active.startTime, active.endTime);

  final currentPatrol = PatrolRound(
    roundInterval.start,
    'Round ${_twoDigit(active.roundNumber)} (${formatTime12h(active.startTime)} - ${formatTime12h(active.endTime)})',
    active.roundNumber,
    scanWindowOpen: activeWindow.start,
    scanWindowClose: activeWindow.end,
  );

  final nextPatrol = PatrolRound(
    nextWindow.start,
    'Round ${_twoDigit(next.roundNumber)} (${formatTime12h(next.startTime)} - ${formatTime12h(next.endTime)})',
    next.roundNumber,
    scanWindowOpen: nextWindow.start,
    scanWindowClose: nextWindow.end,
  );

  return {
    'current': currentPatrol,
    'next': nextPatrol,
    'currentRoundTime': roundInterval.start,
    'nextRoundTime': nextWindow.start,
    'currentRoundLabel': currentPatrol.label,
    'currentRoundNumber': currentPatrol.round,
    'scanWindowOpen': activeWindow.start,
    'scanWindowClose': activeWindow.end,
    'isActive': status.isScanWindowActive,
  };
}
