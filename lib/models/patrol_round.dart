// lib/models/patrol_round.dart
// Model for a patrol round fetched from the backend.
// Includes operational round times and the separate scan window times.

import 'dart:convert';

class DbPatrolRound {
  final String id;
  final String factoryCode;
  final int roundNumber;
  final String startTime; // "HH:mm" 24h
  final String endTime;   // "HH:mm"
  final String scanStartTime; // "HH:mm"
  final String scanEndTime;   // "HH:mm"

  DbPatrolRound({
    required this.id,
    this.factoryCode = 'F001',
    required this.roundNumber,
    required this.startTime,
    required this.endTime,
    required this.scanStartTime,
    required this.scanEndTime,
  });

  factory DbPatrolRound.fromJson(Map<String, dynamic> json) {
    return DbPatrolRound(
      id: (json['id'] ?? '').toString(),
      factoryCode: (json['factory_code'] ?? 'F001').toString(),
      roundNumber: json['round_number'] is int
          ? json['round_number']
          : int.tryParse(json['round_number'].toString()) ?? 1,
      startTime: (json['start_time'] ?? '06:00').toString(),
      endTime: (json['end_time'] ?? '07:00').toString(),
      scanStartTime: (json['scan_start_time'] ?? '06:55').toString(),
      scanEndTime: (json['scan_end_time'] ?? '07:20').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'factory_code': factoryCode,
        'round_number': roundNumber,
        'start_time': startTime,
        'end_time': endTime,
        'scan_start_time': scanStartTime,
        'scan_end_time': scanEndTime,
      };

  @override
  String toString() => jsonEncode(toJson());
}
