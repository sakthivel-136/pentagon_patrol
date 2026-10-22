// lib/round_utils.dart
// Database-driven & offline-first utilities for Patrol Rounds & Scan Window Engine.
// Supports multi-factory dynamic rounds (DbPatrolRound, RoundStatus)
// and legacy compatibility helpers (PatrolRound, buildPatrolRounds, getCurrentPatrolRound).

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/patrol_round.dart';
import 'd1_client.dart';

// ==============================================================================
// LEGACY COMPATIBILITY MODELS & ADAPTERS
// ==============================================================================

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

// Converts a 24h "HH:mm" time string into a 12h "hh:mm a" string
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
// TIME INTERVAL RESOLVER (HANDLES MIDNIGHT CROSSOVER)
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
// DATABASE-DRIVEN PATROL ROUNDS & FACTORY CACHING
// ==============================================================================

String _cacheKey(String factoryCode) => 'pentagon_cached_rounds_$factoryCode';

/// Generates standard 33 fallback rounds for a factory if database/cache is completely empty.
List<DbPatrolRound> getFallbackDbRounds(String factoryCode) {
  final List<DbPatrolRound> list = [];
  // 33 rounds spaced evenly across 24h
  for (int i = 0; i < 33; i++) {
    final roundNum = i + 1;
    final totalMinutes = ((roundNum - 1) * 45) % (24 * 60);
    final sH = totalMinutes ~/ 60;
    final sM = totalMinutes % 60;
    final endMinutes = (totalMinutes + 45) % (24 * 60);
    final eH = endMinutes ~/ 60;
    final eM = endMinutes % 60;

    final scanStartMinutes = (totalMinutes - 5 + (24 * 60)) % (24 * 60);
    final ssH = scanStartMinutes ~/ 60;
    final ssM = scanStartMinutes % 60;

    final scanEndMinutes = (totalMinutes + 20) % (24 * 60);
    final seH = scanEndMinutes ~/ 60;
    final seM = scanEndMinutes % 60;

    list.add(DbPatrolRound(
      id: 'rnd-$factoryCode-$roundNum',
      factoryCode: factoryCode,
      roundNumber: roundNum,
      startTime: '${_twoDigit(sH)}:${_twoDigit(sM)}',
      endTime: '${_twoDigit(eH)}:${_twoDigit(eM)}',
      scanStartTime: '${_twoDigit(ssH)}:${_twoDigit(ssM)}',
      scanEndTime: '${_twoDigit(seH)}:${_twoDigit(seM)}',
    ));
  }
  return list;
}

/// Loads rounds for a specific factory.
/// Attempts to query Cloudflare D1 first; falls back to local SharedPreferences cache.
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
          .toList();
      // Update local cache
      await saveCachedRounds(resolvedFactory, rounds);
      debugPrint("Loaded ${rounds.length} rounds from D1 for factory $resolvedFactory");
      return rounds;
    }
  } catch (e) {
    debugPrint("Failed to fetch rounds from D1 for $resolvedFactory, falling back to cache: $e");
  }

  // 2. Fallback to cached rounds
  final cached = await getCachedRounds(resolvedFactory);
  if (cached.isNotEmpty) {
    debugPrint("Loaded ${cached.length} cached rounds for factory $resolvedFactory");
    return cached;
  }

  // 3. Fallback to generated default rounds
  debugPrint("No cached rounds found, using fallback 33 rounds for $resolvedFactory");
  final fallback = getFallbackDbRounds(resolvedFactory);
  await saveCachedRounds(resolvedFactory, fallback);
  return fallback;
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

/// Analyzes [now] against the configured [rounds] for a factory to determine:
/// - If a scan window is currently open (guard login allowed)
/// - The active round and how much time remains
/// - The next scheduled scan window and countdown until it opens
FactoryRoundStatus getFactoryRoundStatus(DateTime now, List<DbPatrolRound> rounds) {
  if (rounds.isEmpty) {
    return FactoryRoundStatus(
      isScanWindowActive: true, // Default open if unconfigured
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

  // 1. Check if now falls inside ANY round's scan window
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
    final roundInterval = resolveWindowInterval(now, activeRound.startTime, activeRound.endTime);
    final start12 = DateFormat('hh:mm a').format(roundInterval.start);
    final end12 = DateFormat('hh:mm a').format(roundInterval.end);
    label = 'Round ${_twoDigit(activeRound.roundNumber)} ($start12 – $end12)';

    final scanStart12 = DateFormat('hh:mm a').format(activeWindowStart);
    final scanEnd12 = DateFormat('hh:mm a').format(activeWindowEnd);
    scanWindow = '$scanStart12 – $scanEnd12';
  } else if (nextRound != null) {
    label = 'Next: Round ${_twoDigit(nextRound.roundNumber)}';
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
// LEGACY COMPATIBILITY HELPERS (Used by existing UI callers)
// ==============================================================================

List<DateTime> _buildDaySlots(DateTime date) {
  final base = DateTime(date.year, date.month, date.day);
  return List<DateTime>.generate(
    16,
    (index) => DateTime(base.year, base.month, base.day, 6 + index),
  );
}

List<DateTime> _buildNightSlots(DateTime date) {
  final base = DateTime(date.year, date.month, date.day);
  return [
    DateTime(base.year, base.month, base.day, 22, 0),
    DateTime(base.year, base.month, base.day, 22, 30),
    DateTime(base.year, base.month, base.day, 23, 0),
    DateTime(base.year, base.month, base.day, 23, 30),
  ];
}

List<DateTime> _buildEarlyMorningSlots(DateTime date) {
  final base = DateTime(date.year, date.month, date.day);
  return List<DateTime>.generate(
    12,
    (index) => DateTime(base.year, base.month, base.day, index ~/ 2, (index % 2) * 30),
  );
}

List<PatrolRound> buildPatrolRounds(DateTime now) {
  final localDay = DateTime(now.year, now.month, now.day);
  final cycleStart = now.hour < 6 ? localDay.subtract(const Duration(days: 1)) : localDay;
  final cycleEndDay = cycleStart.add(const Duration(days: 1));

  final slots = <DateTime>[];
  slots.addAll(_buildDaySlots(cycleStart));
  slots.addAll(_buildNightSlots(cycleStart));
  slots.addAll(_buildEarlyMorningSlots(cycleEndDay));
  slots.sort();

  return List<PatrolRound>.generate(
    slots.length,
    (index) => PatrolRound(
      slots[index],
      DateFormat('h:mm a').format(slots[index]),
      index + 1,
      scanWindowOpen: slots[index].subtract(const Duration(minutes: 5)),
      scanWindowClose: slots[index].add(const Duration(minutes: 15)),
    ),
  );
}

DateTime getScanWindowStart(DateTime roundStart) {
  return roundStart.subtract(const Duration(minutes: 5));
}

DateTime getScanWindowEnd(DateTime roundStart) {
  return roundStart.add(const Duration(minutes: 15));
}

bool isWithinPatrolScanWindow(DateTime now, DateTime roundStart) {
  final start = getScanWindowStart(roundStart);
  final end = getScanWindowEnd(roundStart);
  return !now.isBefore(start) && now.isBefore(end);
}

Map<String, dynamic> getCurrentPatrolRound(DateTime now, {List<DbPatrolRound>? dbRounds}) {
  if (dbRounds != null && dbRounds.isNotEmpty) {
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
      'Round ${_twoDigit(active.roundNumber)} (${formatTime12h(active.startTime)})',
      active.roundNumber,
      scanWindowOpen: activeWindow.start,
      scanWindowClose: activeWindow.end,
    );

    final nextPatrol = PatrolRound(
      nextWindow.start,
      'Round ${_twoDigit(next.roundNumber)} (${formatTime12h(next.startTime)})',
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

  // Legacy fallback
  final rounds = buildPatrolRounds(now);
  PatrolRound current = rounds.first;
  int currentIndex = 0;
  bool foundActive = false;

  for (var i = 0; i < rounds.length; i++) {
    final start = getScanWindowStart(rounds[i].time);
    final end = getScanWindowEnd(rounds[i].time);
    if (!now.isBefore(start) && now.isBefore(end)) {
      current = rounds[i];
      currentIndex = i;
      foundActive = true;
      break;
    }
  }

  if (!foundActive) {
    for (var i = 0; i < rounds.length; i++) {
      final start = getScanWindowStart(rounds[i].time);
      if (now.isBefore(start)) {
        current = rounds[i];
        currentIndex = i;
        break;
      }
      current = rounds[i];
      currentIndex = i;
    }
  }

  final next = currentIndex < rounds.length - 1 ? rounds[currentIndex + 1] : rounds.first;

  return {
    'current': current,
    'next': next,
    'currentRoundTime': current.time,
    'nextRoundTime': next.time,
    'currentRoundLabel': current.label,
    'currentRoundNumber': current.round,
    'scanWindowOpen': getScanWindowStart(current.time),
    'scanWindowClose': getScanWindowEnd(current.time),
    'isActive': foundActive,
  };
}

DateTime getNearestPatrolRoundStart(DateTime now) {
  final info = getCurrentPatrolRound(now);
  return info['currentRoundTime'] as DateTime;
}
