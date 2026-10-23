// lib/shift_utils.dart
// Shift Management and Guard Shift Enforcement Engine for Pentagon Patrol.
// Enforces that security guards can only log in during their allocated shift.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/shift.dart';
import 'd1_client.dart';
import 'round_utils.dart';

class ShiftValidationResult {
  final bool isAllowed;
  final DbShift? activeShift;
  final String? errorMessage;
  final bool hasShiftConfigured;

  ShiftValidationResult({
    required this.isAllowed,
    this.activeShift,
    this.errorMessage,
    this.hasShiftConfigured = true,
  });
}

/// Checks whether [now] falls within the interval [[startHhmm], [endHhmm]).
/// Supports normal daytime shifts (e.g. 06:00 - 18:00) and
/// overnight cross-midnight shifts (e.g. 18:00 - 06:00).
bool isTimeWithinShift(DateTime now, String startHhmm, String endHhmm) {
  try {
    final sParts = startHhmm.split(':').map(int.parse).toList();
    final eParts = endHhmm.split(':').map(int.parse).toList();

    final sMinutes = sParts[0] * 60 + sParts[1];
    final eMinutes = eParts[0] * 60 + eParts[1];
    final nowMinutes = now.hour * 60 + now.minute;

    if (sMinutes < eMinutes) {
      // Normal shift within same calendar day
      return nowMinutes >= sMinutes && nowMinutes < eMinutes;
    } else if (sMinutes > eMinutes) {
      // Overnight shift crossing midnight (e.g. 18:00 to 06:00)
      return nowMinutes >= sMinutes || nowMinutes < eMinutes;
    } else {
      // 24-hour shift
      return true;
    }
  } catch (e) {
    debugPrint("isTimeWithinShift error: $e");
    return true;
  }
}

String _shiftsCacheKey(String factoryCode) => 'pentagon_cached_shifts_$factoryCode';
String _shiftAllocCacheKey(String shiftId) => 'pentagon_cached_shift_allocs_$shiftId';

/// Fetches active shifts for a factory from D1 or local cache.
Future<List<DbShift>> loadShiftsForFactory(String factoryCode) async {
  final resolvedFactory = (factoryCode.isEmpty || factoryCode == 'ADMIN') ? 'F001' : factoryCode;

  try {
    final rows = await D1Client.query(
      'SELECT id, factory_code, shift_name, shift_code, start_time, end_time, '
      'scan_interval_mins, scan_window_mins, is_active '
      'FROM shifts WHERE factory_code = ? AND is_active = 1 ORDER BY start_time ASC',
      [resolvedFactory],
    ).timeout(const Duration(seconds: 8));

    if (rows.isNotEmpty) {
      final shifts = rows.map((r) => DbShift.fromJson(Map<String, dynamic>.from(r))).toList();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_shiftsCacheKey(resolvedFactory), jsonEncode(shifts.map((s) => s.toJson()).toList()));
      } catch (_) {}
      return shifts;
    }
  } catch (e) {
    debugPrint("loadShiftsForFactory D1 query failed, checking offline cache: $e");
  }

  // Fallback to local cache
  try {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_shiftsCacheKey(resolvedFactory));
    if (cached != null && cached.isNotEmpty) {
      final List<dynamic> list = jsonDecode(cached);
      return list.map((item) => DbShift.fromJson(Map<String, dynamic>.from(item))).toList();
    }
  } catch (e) {
    debugPrint("loadShiftsForFactory cache read error: $e");
  }

  return [];
}

/// Fetches guard IDs allocated to a specific shift from D1 or local cache.
Future<List<String>> loadAllocatedGuardsForShift(String shiftId) async {
  if (shiftId.isEmpty) return [];

  try {
    final rows = await D1Client.query(
      'SELECT security_id FROM shift_allocations WHERE shift_id = ?',
      [shiftId],
    ).timeout(const Duration(seconds: 8));

    final guardIds = rows
        .map((r) => r['security_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_shiftAllocCacheKey(shiftId), jsonEncode(guardIds));
    } catch (_) {}

    return guardIds;
  } catch (e) {
    debugPrint("loadAllocatedGuardsForShift D1 query failed, checking cache: $e");
  }

  // Fallback to local cache
  try {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_shiftAllocCacheKey(shiftId));
    if (cached != null && cached.isNotEmpty) {
      final List<dynamic> list = jsonDecode(cached);
      return list.map((e) => e.toString()).toList();
    }
  } catch (e) {
    debugPrint("loadAllocatedGuardsForShift cache read error: $e");
  }

  return [];
}

/// Pre-caches shifts and allocations for all given factories in background.
Future<void> prefetchShiftsAndAllocations(Iterable<String> factoryCodes) async {
  for (final fc in factoryCodes) {
    try {
      final shifts = await loadShiftsForFactory(fc);
      for (final s in shifts) {
        await loadAllocatedGuardsForShift(s.id);
      }
    } catch (_) {}
  }
}

/// Validates whether a security guard is authorized to log in during the current shift.
/// - If no shifts configured: permits login.
/// - If current time doesn't match any shift: denies login.
/// - If current active shift has no guards allocated yet: permits factory guards by default.
/// - If current active shift has allocations: checks if guard's security_id is allocated.
Future<ShiftValidationResult> validateGuardShiftAccess({
  required String factoryCode,
  required String securityId,
  DateTime? currentTime,
}) async {
  final now = currentTime ?? DateTime.now();
  final shifts = await loadShiftsForFactory(factoryCode);

  // If no shifts are configured at all, don't block
  if (shifts.isEmpty) {
    return ShiftValidationResult(
      isAllowed: true,
      hasShiftConfigured: false,
    );
  }

  // Find currently active shift
  DbShift? activeShift;
  for (final s in shifts) {
    if (isTimeWithinShift(now, s.startTime, s.endTime)) {
      activeShift = s;
      break;
    }
  }

  if (activeShift == null) {
    return ShiftValidationResult(
      isAllowed: false,
      hasShiftConfigured: true,
      errorMessage: 'No active shift is currently scheduled for factory $factoryCode at this time.',
    );
  }

  // Check allocated guards for this active shift
  final allocatedGuardIds = await loadAllocatedGuardsForShift(activeShift.id);

  // If no guard allocations configured yet, default permits all guards
  if (allocatedGuardIds.isEmpty) {
    return ShiftValidationResult(
      isAllowed: true,
      activeShift: activeShift,
      hasShiftConfigured: true,
    );
  }

  // Check if this guard is assigned to the active shift
  final isAllocated = allocatedGuardIds.contains(securityId);
  if (isAllocated) {
    return ShiftValidationResult(
      isAllowed: true,
      activeShift: activeShift,
      hasShiftConfigured: true,
    );
  }

  // Guard NOT allocated to active shift
  final formattedStart = formatTime12h(activeShift.startTime);
  final formattedEnd = formatTime12h(activeShift.endTime);
  return ShiftValidationResult(
    isAllowed: false,
    activeShift: activeShift,
    hasShiftConfigured: true,
    errorMessage:
        'Access Denied: You are not assigned to the active ${activeShift.shiftName} ($formattedStart - $formattedEnd).',
  );
}
