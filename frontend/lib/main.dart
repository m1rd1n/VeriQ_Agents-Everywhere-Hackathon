import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';

const _screenshotEvents = EventChannel('com.semakqr/screenshot_events');

void main() => runApp(const SemakQrApp());

/// Entry point launched by flutter_overlay_window in a separate Flutter engine.
@pragma('vm:entry-point')
void overlayMain() => runApp(
  const MaterialApp(debugShowCheckedModeBanner: false, home: OverlayView()),
);

class SemakQrApp extends StatefulWidget {
  const SemakQrApp({super.key});
  @override
  State<SemakQrApp> createState() => _SemakQrAppState();
}

class _SemakQrAppState extends State<SemakQrApp> {
  StreamSubscription<dynamic>? _screenshots;
  String _status = 'Preparing Semak QR...';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // Permission is required only to observe screenshot additions; images are
    // never saved or copied by this app.
    await Permission.photos.request();
    final allowed = await FlutterOverlayWindow.isPermissionGranted();
    if (!allowed) await FlutterOverlayWindow.requestPermission();
    final granted = await FlutterOverlayWindow.isPermissionGranted();
    if (!mounted) return;
    if (!granted) {
      setState(
        () => _status =
            'Allow "Display over other apps" in Settings, then reopen Semak QR.',
      );
      return;
    }
    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: 'Semak QR',
      overlayContent: 'Tap to check a payment screenshot',
      flag: OverlayFlag.defaultFlag,
      visibility: NotificationVisibility.visibilityPublic,
      positionGravity: PositionGravity.auto,
      height: 72,
      width: 72,
    );
    _screenshots = _screenshotEvents.receiveBroadcastStream().listen((_) {
      // Android gives us notification of the new item only. No path is kept;
      // the user can select the image manually if the OS blocks access.
      FlutterOverlayWindow.shareData('screenshot_detected');
    });
    setState(
      () => _status =
          'Overlay is active. Take a screenshot, or use Upload in the bubble.',
    );
  }

  @override
  void dispose() {
    _screenshots?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      appBar: AppBar(title: const Text('Semak QR')),
      body: Padding(padding: const EdgeInsets.all(24), child: Text(_status)),
    ),
  );
}

class OverlayView extends StatefulWidget {
  const OverlayView({super.key});
  @override
  State<OverlayView> createState() => _OverlayViewState();
}

class _OverlayViewState extends State<OverlayView>
    with SingleTickerProviderStateMixin {
  final _picker = ImagePicker();
  StreamSubscription? _overlayEvents;
  late final AnimationController _pulse;
  bool _expanded = false;
  bool _loading = false;
  String _step = '';
  CheckResult? _result;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    )..repeat(reverse: true);
    _overlayEvents = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event == 'screenshot_detected') {
        _expand('Screenshot detected - choose it to check');
      }
    });
  }

  @override
  void dispose() {
    _overlayEvents?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _expand([String? message]) async {
    await FlutterOverlayWindow.resizeOverlay(320, 370);
    if (mounted)
      setState(() {
        _expanded = true;
        if (message != null) _step = message;
      });
  }

  Future<void> _chooseAndCheck() async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (image == null) return;
    await _check(image);
  }

  Future<void> _previewFlaggedResult() async {
    await _expand();
    setState(() {
      _loading = true;
      _result = null;
      _step = 'Checking scam database...';
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = const CheckResult(
        riskLevel: 'high',
        reason: 'This recipient is flagged in scam reports. Do not transfer money.',
        evidence: [
          'Matched a reported scam-account record',
          'Web reports indicate possible mule-account activity',
        ],
      );
    });
  }

  Future<void> _check(XFile image) async {
    await _expand();
    setState(() {
      _loading = true;
      _result = null;
      _step = 'Reading payment details...';
    });
    try {
      if (backendUrl.isEmpty)
        throw const _CheckException('Backend URL has not been configured.');
      final result = await _postWithRetry(image);
      if (mounted)
        setState(() {
          _result = result;
          _loading = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _result = const CheckResult(
            riskLevel: 'unknown',
            reason: "Couldn't check right now — proceed carefully",
            evidence: [],
          );
        });
    }
    // The XFile is intentionally not retained. No screenshot or extracted data
    // is cached or written by Semak QR after this request completes.
  }

  Future<CheckResult> _postWithRetry(XFile image) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt == 1 && mounted)
          setState(() => _step = 'Trying once more...');
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$backendUrl/check-transaction'),
        );
        request.files.add(
          await http.MultipartFile.fromPath('screenshot', image.path),
        );
        final streamed = await request.send().timeout(
          const Duration(seconds: 10),
        );
        final response = await http.Response.fromStream(
          streamed,
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200)
          throw const _CheckException('Request failed');
        return CheckResult.fromJson(response.body);
      } catch (error) {
        lastError = error;
      }
    }
    throw _CheckException('$lastError');
  }

  Future<void> _collapse() async {
    await FlutterOverlayWindow.resizeOverlay(72, 72);
    if (mounted)
      setState(() {
        _expanded = false;
        _result = null;
      });
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Stack(
      children: [
        if (_expanded)
          Positioned.fill(
            child: GestureDetector(
              onTap: _collapse,
              behavior: HitTestBehavior.opaque,
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: _expanded ? null : _expand,
            child: _expanded ? _card() : _bubble(),
          ),
        ),
      ],
    ),
  );

  Widget _bubble() => Container(
    margin: const EdgeInsets.only(right: 12),
    width: 64,
    height: 64,
    decoration: const BoxDecoration(
      color: Color(0xFF006E5B),
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 8)],
    ),
    child: const Icon(
      Icons.qr_code_scanner_rounded,
      color: Colors.white,
      size: 30,
    ),
  );

  Widget _card() => Container(
    width: 296,
    margin: const EdgeInsets.only(right: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 14)],
    ),
    child: _loading
        ? _loadingCard()
        : _result == null
        ? _startCard()
        : _resultCard(_result!),
  );

  Widget _startCard() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Semak QR',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Upload a payment-confirmation screenshot to check the recipient before you pay.',
      ),
      const SizedBox(height: 14),
      if (demoMode) ...[
        FilledButton.icon(
          onPressed: _previewFlaggedResult,
          icon: const Icon(Icons.visibility),
          label: const Text('Preview flagged result'),
        ),
        const SizedBox(height: 8),
      ],
      FilledButton.icon(
        onPressed: _chooseAndCheck,
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload screenshot'),
      ),
    ],
  );

  Widget _loadingCard() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      FadeTransition(opacity: _pulse, child: const CircularProgressIndicator()),
      const SizedBox(height: 14),
      Text(_step, textAlign: TextAlign.center),
      const SizedBox(height: 4),
      const Text(
        'Checking database and web signals...',
        style: TextStyle(fontSize: 12, color: Colors.black54),
      ),
    ],
  );

  Widget _resultCard(CheckResult result) {
    final color = switch (result.riskLevel) {
      'high' => Colors.red.shade700,
      'medium' => Colors.amber.shade800,
      _ => Colors.green.shade700,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Check result',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                result.riskLevel.toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(result.reason),
        if (result.evidence.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...result.evidence
              .take(2)
              .map((e) => Text('- $e', style: const TextStyle(fontSize: 12))),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _collapse,
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: _collapse,
                child: const Text('Proceed anyway'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class CheckResult {
  const CheckResult({
    required this.riskLevel,
    required this.reason,
    required this.evidence,
  });
  final String riskLevel, reason;
  final List<String> evidence;
  factory CheckResult.fromJson(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    return CheckResult(
      riskLevel: json['risk_level'] as String? ?? 'unknown',
      reason:
          json['reason'] as String? ??
          "Couldn't check right now — proceed carefully",
      evidence: (json['evidence'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

class _CheckException implements Exception {
  const _CheckException(this.message);
  final String message;
}
