import 'package:flutter_test/flutter_test.dart';
import 'package:veripatrol/shift_utils.dart';
import 'package:veripatrol/round_utils.dart';

void main() {
  group('Shift Time Logic Tests', () {
    test('Daytime shift (06:00 to 18:00)', () {
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 5, 59), '06:00', '18:00'), isFalse);
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 6, 0), '06:00', '18:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 12, 30), '06:00', '18:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 17, 59), '06:00', '18:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 18, 0), '06:00', '18:00'), isFalse);
    });

    test('Overnight shift (18:00 to 06:00)', () {
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 17, 59), '18:00', '06:00'), isFalse);
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 18, 0), '18:00', '06:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 23, 23, 45), '18:00', '06:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 24, 0, 0), '18:00', '06:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 24, 3, 30), '18:00', '06:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 24, 5, 59), '18:00', '06:00'), isTrue);
      expect(isTimeWithinShift(DateTime(2026, 10, 24, 6, 0), '18:00', '06:00'), isFalse);
    });

    test('formatTime12h display conversion', () {
      expect(formatTime12h('06:00'), '06:00 AM');
      expect(formatTime12h('12:00'), '12:00 PM');
      expect(formatTime12h('18:00'), '06:00 PM');
      expect(formatTime12h('00:00'), '12:00 AM');
      expect(formatTime12h('23:45'), '11:45 PM');
    });
  });
}
