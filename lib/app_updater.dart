import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final String releaseNotes;
  final bool isMandatory;

  AppUpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.releaseNotes,
    this.isMandatory = false,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      version: json['version']?.toString() ?? '1.0.0',
      buildNumber: int.tryParse(json['build_number']?.toString() ?? '1') ?? 1,
      downloadUrl: json['download_url']?.toString() ??
          'https://github.com/sakthivel-136/pentagon_patrol/releases/download/latest-apk/app-release.apk',
      releaseNotes: json['release_notes']?.toString() ?? 'New security updates and performance improvements.',
      isMandatory: json['is_mandatory'] == true,
    );
  }
}

class AppUpdater {
  static const MethodChannel _channel = MethodChannel('com.veripatrol/app_updater');

  // Direct version manifest hosted on GitHub Releases (No API limits)
  static const String _versionJsonUrl =
      'https://github.com/sakthivel-136/pentagon_patrol/releases/download/latest-apk/version.json';

  // Fallback to GitHub Releases API
  static const String _githubApiUrl =
      'https://api.github.com/repos/sakthivel-136/pentagon_patrol/releases/tags/latest-apk';

  /// Check for available updates
  static Future<AppUpdateInfo?> checkUpdate() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 1;

      // 1. Try version.json directly
      try {
        final res = await http.get(Uri.parse(_versionJsonUrl)).timeout(const Duration(seconds: 7));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final updateInfo = AppUpdateInfo.fromJson(data);
          if (updateInfo.buildNumber > currentBuildNumber ||
              _isNewerVersion(updateInfo.version, packageInfo.version)) {
            return updateInfo;
          }
          return null; // Up to date
        }
      } catch (e) {
        debugPrint('[AppUpdater] Direct version.json check failed: $e. Trying GitHub API...');
      }

      // 2. Fallback to GitHub Releases API
      final apiRes = await http.get(
        Uri.parse(_githubApiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 8));

      if (apiRes.statusCode == 200) {
        final data = jsonDecode(apiRes.body);
        final assets = (data['assets'] as List?) ?? [];
        String downloadUrl = '';
        for (var a in assets) {
          if (a['name']?.toString().endsWith('.apk') == true) {
            downloadUrl = a['browser_download_url'] ?? '';
            break;
          }
        }

        if (downloadUrl.isEmpty) {
          downloadUrl =
              'https://github.com/sakthivel-136/pentagon_patrol/releases/download/latest-apk/app-release.apk';
        }

        final body = data['body']?.toString() ?? 'Security updates and improvements.';
        // Extract build number or version from tag or body if present
        return AppUpdateInfo(
          version: data['name']?.toString() ?? 'Latest',
          buildNumber: currentBuildNumber + 1, // Indicate update available if triggered
          downloadUrl: downloadUrl,
          releaseNotes: body,
        );
      }
    } catch (e) {
      debugPrint('[AppUpdater] Check update error: $e');
    }
    return null;
  }

  static bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.replaceAll('v', '').split('.').map(int.parse).toList();
      final currentParts = current.replaceAll('v', '').split('.').map(int.parse).toList();
      for (int i = 0; i < latestParts.length && i < currentParts.length; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
      return latestParts.length > currentParts.length;
    } catch (_) {
      return false;
    }
  }

  /// Triggers install via Android Package Installer
  static Future<void> installApk(String filePath) async {
    try {
      await _channel.invokeMethod('installApk', {'filePath': filePath});
    } on PlatformException catch (e) {
      debugPrint('[AppUpdater] Install APK failed: ${e.message}');
      rethrow;
    }
  }

  /// Check & show update dialog if available
  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool silentIfLatest = true,
  }) async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final updateInfo = await checkUpdate();

      if (!context.mounted) return;

      if (updateInfo != null) {
        showDialog(
          context: context,
          barrierDismissible: !updateInfo.isMandatory,
          builder: (ctx) => _UpdateDialog(
            updateInfo: updateInfo,
            currentVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
          ),
        );
      } else if (!silentIfLatest) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('App is up to date! (v${packageInfo.version}+${packageInfo.buildNumber})'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('[AppUpdater] Prompt error: $e');
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;
  final String currentVersion;

  const _UpdateDialog({
    required this.updateInfo,
    required this.currentVersion,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _downloadStatus = '';

  Future<void> _startDownloadAndInstall() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _downloadStatus = 'Connecting...';
    });

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(widget.updateInfo.downloadUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Download failed with server status ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/pentagon_patrol_update.apk');
      if (await file.exists()) {
        await file.delete();
      }

      final sink = file.openWrite();

      await response.stream.listen(
        (chunk) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0) {
            setState(() {
              _progress = receivedBytes / totalBytes;
              final mbReceived = (receivedBytes / (1024 * 1024)).toStringAsFixed(1);
              final mbTotal = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
              _downloadStatus = '$mbReceived MB / $mbTotal MB (${(_progress * 100).toInt()}%)';
            });
          } else {
            setState(() {
              final mbReceived = (receivedBytes / (1024 * 1024)).toStringAsFixed(1);
              _downloadStatus = '$mbReceived MB downloaded';
            });
          }
        },
        onDone: () async {
          await sink.flush();
          await sink.close();
          client.close();

          setState(() {
            _downloadStatus = 'Installing update...';
          });

          await AppUpdater.installApk(file.path);
        },
        onError: (e) {
          sink.close();
          client.close();
          throw e;
        },
        cancelOnError: true,
      ).asFuture();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadStatus = 'Error downloading update: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Update failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.system_update, color: Colors.blue, size: 28),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Update Available',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Current Version:', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                      Text(widget.currentVersion, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('New Version:', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                      Text(
                        'v${widget.updateInfo.version} (Build ${widget.updateInfo.buildNumber})',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "What's New:",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              widget.updateInfo.releaseNotes,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
            ),
            if (_isDownloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: Colors.grey.shade300,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                minHeight: 8,
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  _downloadStatus,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!widget.updateInfo.isMandatory && !_isDownloading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later', style: TextStyle(color: Colors.grey)),
          ),
        if (!_isDownloading)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _startDownloadAndInstall,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Update Now'),
          ),
      ],
    );
  }
}
