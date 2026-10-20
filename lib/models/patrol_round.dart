// lib/models/patrol_round.dart
// Model for a patrol round fetched from the backend.
// Includes operational round times and the separate scan window times.

import 'dart:convert';

class DbPatrolRound {
  final String id;
  final int roundNumber;
  final String startTime; // "HH:mm" 24h
  final String endTime;   // "HH:mm"
  final String scanStartTime; // "HH:mm"
  final String scanEndTime;   // "HH:mm"

  DbPatrolRound({
    required this.id,
    required this.roundNumber,
    required this.startTime,
    required this.endTime,
    required this.scanStartTime,
    required this.scanEndTime,
  });

  factory DbPatrolRound.fromJson(Map<String, dynamic> json) {
    return DbPatrolRound(
      id: json['id'] as String,
      roundNumber: json['round_number'] as int,
      startTime: json['start_time'] as String,
      endTime: json['end_time'] as String,
      scanStartTime: json['scan_start_time'] as String,
      scanEndTime: json['scan_end_time'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'round_number': roundNumber,
        'start_time': startTime,
        'end_time': endTime,
        'scan_start_time': scanStartTime,
        'scan_end_time': scanEndTime,
      };

  @override
  String toString() => jsonEncode(toJson());
}
