// lib/models/shift.dart
// Database-driven Shift Model for Pentagon Patrol.

import 'dart:convert';

class DbShift {
  final String id;
  final String factoryCode;
  final String shiftName;
  final String shiftCode;
  final String startTime; // "HH:mm" (24h)
  final String endTime;   // "HH:mm" (24h)
  final int scanIntervalMins;
  final int scanWindowMins;
  final bool isActive;

  DbShift({
    required this.id,
    required this.factoryCode,
    required this.shiftName,
    required this.shiftCode,
    required this.startTime,
    required this.endTime,
    this.scanIntervalMins = 60,
    this.scanWindowMins = 15,
    this.isActive = true,
  });

  factory DbShift.fromJson(Map<String, dynamic> json) {
    return DbShift(
      id: (json['id'] ?? '').toString(),
      factoryCode: (json['factory_code'] ?? 'F001').toString(),
      shiftName: (json['shift_name'] ?? 'Shift').toString(),
      shiftCode: (json['shift_code'] ?? 'DAY').toString(),
      startTime: (json['start_time'] ?? '06:00').toString(),
      endTime: (json['end_time'] ?? '18:00').toString(),
      scanIntervalMins: json['scan_interval_mins'] is int
          ? json['scan_interval_mins']
          : int.tryParse(json['scan_interval_mins'].toString()) ?? 60,
      scanWindowMins: json['scan_window_mins'] is int
          ? json['scan_window_mins']
          : int.tryParse(json['scan_window_mins'].toString()) ?? 15,
      isActive: json['is_active'] == 1 ||
          json['is_active'] == true ||
          json['is_active'] == '1',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'factory_code': factoryCode,
        'shift_name': shiftName,
        'shift_code': shiftCode,
        'start_time': startTime,
        'end_time': endTime,
        'scan_interval_mins': scanIntervalMins,
        'scan_window_mins': scanWindowMins,
        'is_active': isActive ? 1 : 0,
      };

  @override
  String toString() => jsonEncode(toJson());
}
