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

class _SemakQrAppState extends State<SemakQrApp> with WidgetsBindingObserver {
  StreamSubscription<dynamic>? _screenshots;
  bool _overlayAllowed = false;
  bool _overlayActive = false;
  bool _checkingBackend = false;
  String _backendStatus = backendBaseUrl.isEmpty
      ? 'Backend URL has not been configured yet.'
      : 'Backend has not been checked.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshOverlayPermission();
    _screenshots = _screenshotEvents.receiveBroadcastStream().listen((_) {
      // The event contains no saved image path. The user chooses a screenshot
      // only when Android blocks automatic access to it.
      FlutterOverlayWindow.shareData('screenshot_detected');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshOverlayPermission();
  }

  Future<void> _refreshOverlayPermission() async {
    final allowed = await FlutterOverlayWindow.isPermissionGranted();
    if (mounted) setState(() => _overlayAllowed = allowed);
  }

  Future<void> _enableOverlay() async {
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await FlutterOverlayWindow.requestPermission();
      await _refreshOverlayPermission();
      return;
    }
    // Photos permission is only for the manual screenshot fallback. Semak QR
    // does not store a selected image or extracted payment data.
    await Permission.photos.request();
    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: 'Semak QR is ready',
      overlayContent: 'Tap the bubble to check a payment.',
      alignment: OverlayAlignment.centerRight,
      flag: OverlayFlag.defaultFlag,
      visibility: NotificationVisibility.visibilityPrivate,
      positionGravity: PositionGravity.auto,
      height: 72,
      width: 72,
    );
    if (mounted) setState(() => _overlayActive = true);
  }

  Future<void> _checkBackend() async {
    if (backendBaseUrl.isEmpty) return;
    setState(() => _checkingBackend = true);
    try {
      final response = await http
          .get(Uri.parse('$backendBaseUrl/health'))
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() => _backendStatus = response.statusCode == 200
          ? 'Backend connected and ready.'
          : 'Backend responded with ${response.statusCode}.');
    } catch (_) {
      if (mounted)
        setState(() => _backendStatus = 'Could not reach the backend.');
    } finally {
      if (mounted) setState(() => _checkingBackend = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenshots?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF006E5B)),
          useMaterial3: true,
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFFF4F8F6),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: const BoxDecoration(
                            color: Color(0xFF006E5B), shape: BoxShape.circle),
                        child: const Icon(Icons.qr_code_scanner_rounded,
                            color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Semak QR',
                                style: TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800)),
                            Text('A final check before you pay',
                                style: TextStyle(color: Colors.black54)),
                          ]),
                    ]),
                    const Spacer(),
                    const Text('Stay one step ahead of scams.',
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            height: 1.08)),
                    const SizedBox(height: 12),
                    const Text(
                        'Enable the floating safety check, then take a payment-confirmation screenshot before transferring money.',
                        style: TextStyle(
                            fontSize: 16, height: 1.45, color: Colors.black87)),
                    const SizedBox(height: 24),
                    _statusCard(
                        Icons.layers_rounded,
                        'Floating overlay',
                        _overlayActive
                            ? 'Active - the bubble is ready above other apps.'
                            : _overlayAllowed
                                ? 'Permission granted - enable the bubble.'
                                : 'Permission required to display the bubble.'),
                    const SizedBox(height: 12),
                    _statusCard(Icons.cloud_outlined, 'Safety-check backend',
                        _backendStatus),
                    const SizedBox(height: 24),
                    SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _enableOverlay,
                          icon: Icon(_overlayAllowed
                              ? Icons.bubble_chart_rounded
                              : Icons.settings_outlined),
                          label: Text(_overlayAllowed
                              ? 'Enable Semak QR overlay'
                              : 'Allow overlay permission'),
                          style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 17)),
                        )),
                    const SizedBox(height: 10),
                    SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _checkingBackend || backendBaseUrl.isEmpty
                              ? null
                              : _checkBackend,
                          icon: _checkingBackend
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.wifi_tethering_rounded),
                          label: const Text('Check backend connection'),
                        )),
                    const SizedBox(height: 18),
                    const Text(
                        'Your screenshots and payment details are processed for the check only. Semak QR does not keep them.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.black54, height: 1.4)),
                  ]),
            ),
          ),
        ),
      );

  Widget _statusCard(IconData icon, String title, String detail) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: const Color(0xFF006E5B)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(detail,
                    style: const TextStyle(fontSize: 13, color: Colors.black54))
              ])),
        ]),
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
    await FlutterOverlayWindow.resizeOverlay(320, 370, true);
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
        reason:
            'This recipient is flagged in scam reports. Do not transfer money.',
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
      if (backendBaseUrl.isEmpty)
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
          Uri.parse('$backendBaseUrl/check-transaction'),
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
    await FlutterOverlayWindow.resizeOverlay(72, 72, true);
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
          FadeTransition(
              opacity: _pulse, child: const CircularProgressIndicator()),
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
      reason: json['reason'] as String? ??
          "Couldn't check right now — proceed carefully",
      evidence:
          (json['evidence'] as List? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

class _CheckException implements Exception {
  const _CheckException(this.message);
  final String message;
}
