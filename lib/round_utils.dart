// lib/round_utils.dart
// Offline-first utilities for Patrol Rounds & Scan Window Engine.
// Supports both dynamic database-driven rounds (DbPatrolRound, RoundStatus)
// and legacy compatibility helpers (PatrolRound, buildPatrolRounds, getCurrentPatrolRound).

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'models/patrol_round.dart';

// ==============================================================================
// LEGACY COMPATIBILITY MODELS & METHODS (Used by main.dart, home_page.dart)
// ==============================================================================

class PatrolRound {
  final DateTime time;
  final String label;
  final int round;

  PatrolRound(this.time, this.label, this.round);
}

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

Map<String, dynamic> getCurrentPatrolRound(DateTime now) {
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

  final next = currentIndex < rounds.length - 1
      ? rounds[currentIndex + 1]
      : rounds.first;

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

// ==============================================================================
// DATABASE-DRIVEN PATROL ROUNDS & SCAN WINDOW ENGINE
// ==============================================================================

const _kCachedRoundsKey = 'cached_patrol_rounds';

String _twoDigit(int n) => n.toString().padLeft(2, '0');

List<DbPatrolRound> getFallbackDbRounds() {
  List<DbPatrolRound> list = [];
  for (int i = 0; i < 33; i++) {
    final startHour = (6 + (i * 2)) % 24;
    final endHour = (startHour + 2) % 24;
    final roundNum = i + 1;
    final start = '${_twoDigit(startHour)}:00';
    final end = '${_twoDigit(endHour)}:00';
    final scanStart = '${_twoDigit(startHour)}:55';
    final scanEnd = '${_twoDigit(endHour)}:20';
    list.add(DbPatrolRound(
      id: 'fallback-$roundNum',
      roundNumber: roundNum,
      startTime: start,
      endTime: end,
      scanStartTime: scanStart,
      scanEndTime: scanEnd,
    ));
  }
  return list;
}

Future<List<DbPatrolRound>> loadCachedRounds() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kCachedRoundsKey);
    if (jsonString != null && jsonString.isNotEmpty) {
      final List<dynamic> raw = json.decode(jsonString) as List<dynamic>;
      return raw.map((e) => DbPatrolRound.fromJson(e as Map<String, dynamic>)).toList();
    }
  } catch (e) {
    debugPrint("loadCachedRounds error: $e");
  }
  return getFallbackDbRounds();
}

Future<void> syncRoundsFromApi({String baseUrl = 'https://pentagon-patrol-api.workers.dev'}) async {
  try {
    final url = Uri.parse('$baseUrl/api/rounds');
    final response = await http.get(url).timeout(const Duration(seconds: 10));
    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body) as List<dynamic>;
      final List<DbPatrolRound> rounds = data
          .map((e) => DbPatrolRound.fromJson(e as Map<String, dynamic>))
          .toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCachedRoundsKey, json.encode(rounds));
    }
  } catch (e) {
    debugPrint("syncRoundsFromApi error: $e");
  }
}

class RoundStatus {
  final bool isScanWindowActive;
  final DbPatrolRound? activeRound;
  final DbPatrolRound? nextRound;
  final Duration? timeUntilNextWindow;
  final Duration? remainingWindowTime;
  final String formattedLabel;
  final String formattedScanWindow;

  RoundStatus({
    required this.isScanWindowActive,
    required this.activeRound,
    required this.nextRound,
    required this.timeUntilNextWindow,
    required this.remainingWindowTime,
    required this.formattedLabel,
    required this.formattedScanWindow,
  });
}

DateTime _parseTime(String hhmm, DateTime reference) {
  final parts = hhmm.split(':');
  final hour = int.parse(parts[0]);
  final minute = int.parse(parts[1]);
  return DateTime(reference.year, reference.month, reference.day, hour, minute);
}

RoundStatus getPatrolRoundStatus(DateTime now, List<DbPatrolRound> rounds) {
  final localNow = now.toLocal();

  DateTime adjustEnd(DateTime start, DateTime end) =>
      end.isBefore(start) ? end.add(const Duration(days: 1)) : end;

  DbPatrolRound? active;
  DbPatrolRound? next;
  Duration? remaining;
  Duration? untilNext;

  for (final r in rounds) {
    final scanStart = _parseTime(r.scanStartTime, localNow);
    final scanEnd = adjustEnd(scanStart, _parseTime(r.scanEndTime, localNow));

    if (!localNow.isBefore(scanStart) && localNow.isBefore(scanEnd)) {
      active = r;
      remaining = scanEnd.difference(localNow);
      break;
    }
  }

  for (final r in rounds) {
    final scanStart = _parseTime(r.scanStartTime, localNow);
    if (localNow.isBefore(scanStart)) {
      next = r;
      untilNext = scanStart.difference(localNow);
      break;
    }
  }

  if (next == null && rounds.isNotEmpty) {
    next = rounds.first;
    final tomorrowStart = _parseTime(next.scanStartTime, localNow).add(const Duration(days: 1));
    untilNext = tomorrowStart.difference(localNow);
  }

  String label = '';
  String scanWindow = '';
  if (active != null) {
    final startDt = _parseTime(active.startTime, localNow);
    final endDt = adjustEnd(startDt, _parseTime(active.endTime, localNow));
    label = 'Round ${_twoDigit(active.roundNumber)} (${DateFormat('hh:mm a').format(startDt)} - ${DateFormat('hh:mm a').format(endDt)})';

    final sStart = _parseTime(active.scanStartTime, localNow);
    final sEnd = adjustEnd(sStart, _parseTime(active.scanEndTime, localNow));
    scanWindow = 'Scan Window: ${DateFormat('hh:mm a').format(sStart)} - ${DateFormat('hh:mm a').format(sEnd)}';
  }

  return RoundStatus(
    isScanWindowActive: active != null,
    activeRound: active,
    nextRound: next,
    timeUntilNextWindow: untilNext,
    remainingWindowTime: remaining,
    formattedLabel: label,
    formattedScanWindow: scanWindow,
  );
}
