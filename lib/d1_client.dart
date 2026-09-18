import 'dart:convert';
import 'package:http/http.dart' as http;

class D1Client {
  static const String baseUrl = 'https://pentagon-patrol-api.srmdatabase2025.workers.dev';

  static Future<List<dynamic>> query(String sql, [List<dynamic>? params]) async {
    final response = await http.post(
      Uri.parse(baseUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'query': sql, 'params': params ?? []}),
    );

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded.containsKey('results')) {
        return List<dynamic>.from(decoded['results']);
      } else if (decoded is List) {
        return List<dynamic>.from(decoded);
      }
      return [];
    } else {
      throw Exception('Failed to execute query: ${response.body}');
    }
  }
}
