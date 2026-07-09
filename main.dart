// ============================================================================
// SmartHelmet Flutter App — FINAL v10 (WHATSAPP PRIMARY, SMS 2ND, TELEGRAM LAST)
// ============================================================================
// ALERT ORDER: WhatsApp (via WhatsScale) tries first. If that fails, Fast2SMS
// tries second. Telegram is the FINAL fallback — it only fires if BOTH
// WhatsApp and SMS have failed. All three are fully automatic — no tap
// needed, works even if rider is unconscious.
//
// ============================================================================
// SETUP — WHATSSCALE (primary channel)
// ============================================================================
// 1. Sign up free at whatsscale.com
// 2. Dashboard → WhatsApp → scan the QR code with your WhatsApp to link it
// 3. Dashboard → Settings → API Keys → Create API Key → copy it
// 4. Get your session name: curl -H "X-Api-Key: YOUR_KEY"
//    https://proxy.whatsscale.com/api/sessions
// 5. Paste both into kWhatsScaleApiKey / kWhatsScaleSession below
//
// SETUP — FAST2SMS (second channel, fires if WhatsApp fails)
// ============================================================================
// 1. Go to https://www.fast2sms.com → Sign up with your phone number (free)
// 2. Go to Dev API (left sidebar) → copy your Authorization API Key
// 3. Paste it into kFast2SmsApiKey below
// 4. Uses the "Quick SMS" route — no DLT/business registration required
//
// SETUP — TELEGRAM (final fallback, fires only if WhatsApp AND SMS both fail)
// ============================================================================
// 1. Message @BotFather on Telegram, /newbot, get your bot token
// 2. Have each emergency contact message your bot and tap START
// 3. Visit https://api.telegram.org/bot<TOKEN>/getUpdates to find each
//    contact's numeric Chat ID
// 4. Paste the token + chat IDs into kTelegramBotToken / kTelegramChatIds below
//
// SECURITY NOTE: rotate your WhatsScale key, Telegram bot token, and Fast2SMS
// API key before shipping this if any have ever been shared/pasted publicly.
//
// ============================================================================
// FEATURES:
//   ✅ WhatsApp PRIMARY — via WhatsScale, sends from your linked WhatsApp
//   ✅ Fast2SMS SECOND — fires only if WhatsApp send fails
//   ✅ Telegram LAST — fires only if both WhatsApp and SMS fail
//   ✅ Nearest Hospital Finder — shows 3 closest hospitals after SOS
//   ✅ Helmet battery status placeholder (ESP32 side needed for real data)
//   ✅ Ride statistics — distance & time since connection
// ============================================================================
//
// pubspec.yaml dependencies:
//   flutter_blue_plus: ^1.32.12
//   geolocator: ^11.0.0
//   permission_handler: ^11.3.1
//   url_launcher: ^6.3.0
//   http: ^1.2.0
//
// AndroidManifest.xml — keep your existing <queries> + permissions block,
// plus <uses-permission android:name="android.permission.INTERNET"/>
// (all three channels send via internet, not telephony)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

// ============================================================================
// BLE UUIDs — must match ESP32 firmware exactly
// ============================================================================
const String kServiceUUID = "12345678-1234-1234-1234-123456789012";
const String kSosCharUUID = "12345678-1234-1234-1234-123456789013";
const String kAckCharUUID = "12345678-1234-1234-1234-123456789014";

// ============================================================================
// ✏️  EDIT THESE BEFORE BUILDING
// ============================================================================
const List<String> kEmergencyContacts = [
  "9042973953",   // 10-digit Indian numbers, NO +91, NO spaces
  "7200401913",
];
const String kRiderName = "Sivanesh";

// 🔑 WHATSSCALE — primary channel. Get from whatsscale.com/dashboard/settings.
const String kWhatsScaleApiKey = "ws_HWIkOGgQHym3hlEs-PW2jObebyhiuDro";
const String kWhatsScaleSession = "user_514835805c234be6b10292ac19d0e5e2_z-WA7UMq";

// 🔑 TELEGRAM — first fallback if WhatsApp fails. Get from @BotFather.
const String kTelegramBotToken = "8905567802:AAFXRhagY4UIUt2Tp_U2QS4_4_Cy82WzBcc";
const List<String> kTelegramChatIds = [
  "7671529139", // Priyadarshan
  "6314243381", // Sivanesh
];

// 🔑 FAST2SMS — final fallback, used only if both WhatsApp and Telegram fail.
const String kFast2SmsApiKey = "yACqD3mcRrn7vBV0YwlM4XUEW1xsSjzLb829ZdK56fePpNgJGuZbe6chwAQuiN2H4RTPs3SyX5I7EmxC";

// ============================================================================
// MAIN
// ============================================================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartHelmetApp());
}

class SmartHelmetApp extends StatelessWidget {
  const SmartHelmetApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartHelmet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE53935),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================================
// HOME PAGE
// ============================================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // BLE
  BluetoothDevice?         _device;
  BluetoothCharacteristic? _sosChar;
  BluetoothCharacteristic? _ackChar;
  bool _bleConnected = false;
  bool _scanning     = false;

  // UI
  String _statusMsg   = "Tap Connect to find SmartHelmet";
  String _lastEvent   = "None";
  bool   _sosActive   = false;
  bool   _smsSending  = false;
  bool   _smsSent     = false;
  String _alertChannel = ""; // "Telegram" or "SMS" — which one actually succeeded
  String _locationStr = "Fetching...";
  double? _lat;
  double? _lng;

  // Hospital finder
  List<_Hospital> _hospitals = [];
  bool _loadingHospitals = false;

  // Ride stats
  DateTime? _connectedSince;

  StreamSubscription? _notifySub;
  StreamSubscription? _scanSub;
  StreamSubscription? _adapterSub;

  @override
  void initState() {
    super.initState();
    _watchAdapter();
    _requestPermissions();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    super.dispose();
  }

  void _watchAdapter() {
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      if (!mounted) return;
      if (s == BluetoothAdapterState.off) {
        _setStatus("❌ Bluetooth is OFF. Please turn it on.");
      }
    });
  }

  // ── PERMISSIONS ───────────────────────────────────────────────────────────
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final locationOn = await Geolocator.isLocationServiceEnabled();
    if (!locationOn && mounted) {
      _setStatus("❌ Location is OFF. Please enable it.");
      await Geolocator.openLocationSettings();
    } else {
      _setStatus("Ready. Tap 'Connect to SmartHelmet'.");
    }
  }

  // ── BLE SCAN ──────────────────────────────────────────────────────────────
  Future<void> _startScan() async {
    final btScan = await Permission.bluetoothScan.isGranted;
    final btConn = await Permission.bluetoothConnect.isGranted;
    final loc    = await Permission.locationWhenInUse.isGranted;
    if (!btScan || !btConn || !loc) {
      await _requestPermissions();
      return;
    }

    await FlutterBluePlus.stopScan();
    setState(() {
      _scanning  = true;
      _statusMsg = "Scanning for SmartHelmet...\nMake sure helmet is powered on.";
    });

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      androidUsesFineLocation: true,
    );

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) async {
      for (final r in results) {
        if (r.device.platformName == "SmartHelmet") {
          await FlutterBluePlus.stopScan();
          _scanSub?.cancel();
          if (mounted) setState(() => _scanning = false);
          await _connectTo(r.device);
          return;
        }
      }
    });

    FlutterBluePlus.isScanning.listen((active) {
      if (!active && _scanning && mounted) {
        setState(() {
          _scanning  = false;
          _statusMsg = "SmartHelmet not found.\n\n"
              "• Is the helmet powered on?\n"
              "• Unpair it from Bluetooth Settings first\n"
              "• Tap Connect to try again";
        });
      }
    });
  }

  // ── BLE CONNECT ───────────────────────────────────────────────────────────
  Future<void> _connectTo(BluetoothDevice device) async {
    _setStatus("Connecting...");
    try {
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      _device = device;

      device.connectionState.listen((state) {
        if (!mounted) return;
        if (state == BluetoothConnectionState.disconnected) {
          _notifySub?.cancel();
          setState(() {
            _bleConnected = false;
            _sosChar = null;
            _ackChar = null;
            _connectedSince = null;
          });
          _setStatus("Helmet disconnected.\nTap Connect to reconnect.");
        }
      });

      _setStatus("Setting up services...");
      final services = await device.discoverServices();
      bool found = false;

      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() != kServiceUUID.toLowerCase()) continue;
        found = true;
        for (final c in svc.characteristics) {
          final uuid = c.uuid.toString().toLowerCase();
          if (uuid == kSosCharUUID.toLowerCase()) {
            _sosChar = c;
            await c.setNotifyValue(true);
            _notifySub?.cancel();
            _notifySub = c.onValueReceived.listen(_onSosNotification);
          }
          if (uuid == kAckCharUUID.toLowerCase()) {
            _ackChar = c;
          }
        }
        break;
      }

      if (mounted) {
        setState(() {
          _bleConnected = true;
          _connectedSince = DateTime.now();
        });
        _setStatus(found
            ? "✅ Helmet connected\nMonitoring for accidents..."
            : "⚠️ Connected but service missing.\nCheck firmware UUIDs.");
      }
    } catch (e) {
      debugPrint("[BLE] Error: $e");
      if (mounted) _setStatus("Connection failed.\nTap Connect to retry.");
    }
  }

  // ── SOS NOTIFICATION FROM ESP32 ───────────────────────────────────────────
  void _onSosNotification(List<int> value) {
    final msg = utf8.decode(value);
    debugPrint("[BLE] Received: $msg");
    if (msg != "SOS" || !mounted) return;
    setState(() {
      _sosActive   = true;
      _smsSent     = false;
      _alertChannel = "";
      _locationStr = "Fetching GPS...";
      _lat = null;
      _lng = null;
      _hospitals = [];
      _lastEvent = "SOS at ${TimeOfDay.now().format(context)}";
    });
    _setStatus("🚨 EMERGENCY! Auto-sending SOS...");
    _triggerAutomaticSOS();
  }

  // ── FULLY AUTOMATIC SOS — Telegram primary, SMS fallback ─────────────────
  Future<void> _triggerAutomaticSOS() async {
    setState(() => _smsSending = true);

    // 1. Get GPS — try fast first, fallback to last known if it takes too long
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );
    } catch (e) {
      debugPrint("[GPS] High accuracy failed, trying last known: $e");
      try {
        pos = await Geolocator.getLastKnownPosition();
      } catch (e2) {
        debugPrint("[GPS] Last known also failed: $e2");
      }
    }

    if (pos != null) {
      _lat = pos.latitude;
      _lng = pos.longitude;
      if (mounted) {
        setState(() => _locationStr =
            "${pos!.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}");
      }
      // Fetch nearest hospitals in parallel
      _fetchNearbyHospitals(pos.latitude, pos.longitude);
    } else {
      if (mounted) setState(() => _locationStr = "Location unavailable");
    }

    // 2. Build message
    final mapsLink = (_lat != null && _lng != null)
        ? "https://maps.google.com/?q=$_lat,$_lng"
        : "Location unavailable";

    final message =
        "ACCIDENT ALERT! Rider $kRiderName needs urgent help. "
        "Location: $mapsLink - Sent automatically by SmartHelmet";

    // 3. Try WhatsApp first (primary), then SMS, then Telegram as last resort.
    bool sent = await _sendWhatsApp(message);
    String channel = "WhatsApp";

    if (!sent) {
      debugPrint("[SOS] WhatsApp failed, falling back to Fast2SMS");
      sent = await _sendAutoSms(message);
      channel = "SMS";
    }

    if (!sent) {
      debugPrint("[SOS] WhatsApp and SMS both failed, falling back to Telegram");
      sent = await _sendTelegram(message);
      channel = "Telegram";
    }

    if (mounted) {
      setState(() {
        _smsSending = false;
        _smsSent = sent;
        _alertChannel = sent ? channel : "";
      });
      _setStatus(sent
          ? "✅ SOS sent automatically via $channel to ${kEmergencyContacts.length} contacts"
          : "⚠️ WhatsApp, SMS, and Telegram all failed. Check internet / API keys.");
    }
  }

  // ── WHATSSCALE API CALL — primary channel ─────────────────────────────────
  // Sends to every contact in kEmergencyContacts. Returns true only if ALL
  // sends succeed — if even one contact doesn't get it, we fall back so no
  // one is left without an alert.
  Future<bool> _sendWhatsApp(String message) async {
    if (kWhatsScaleApiKey == "PASTE_YOUR_WHATSSCALE_API_KEY_HERE") {
      debugPrint("[WhatsApp] API key not configured!");
      return false;
    }

    bool allSucceeded = true;
    for (final phone in kEmergencyContacts) {
      final url = Uri.parse("https://proxy.whatsscale.com/api/sendText");
      try {
        final response = await http.post(
          url,
          headers: {
            "X-Api-Key": kWhatsScaleApiKey,
            "Content-Type": "application/json",
          },
          body: jsonEncode({
            "session": kWhatsScaleSession,
            "chatId": "91$phone@c.us", // 91 = India country code
            "text": message,
          }),
        ).timeout(const Duration(seconds: 10));
        debugPrint("[WhatsApp] $phone -> ${response.statusCode}");
        if (response.statusCode != 200) allSucceeded = false;
      } catch (e) {
        debugPrint("[WhatsApp] Error sending to $phone: $e");
        allSucceeded = false;
      }
    }
    return allSucceeded;
  }

  // ── TELEGRAM API CALL — final fallback (only if WhatsApp AND SMS fail) ────
  // Sends to every chat ID in kTelegramChatIds. Returns true only if ALL
  // sends succeed — if even one contact doesn't get it, we fall back to SMS
  // for everyone so no one is left without an alert.
  Future<bool> _sendTelegram(String message) async {
    if (kTelegramBotToken == "PASTE_YOUR_NEW_TELEGRAM_BOT_TOKEN_HERE") {
      debugPrint("[Telegram] Bot token not configured!");
      return false;
    }

    bool allSucceeded = true;
    for (final chatId in kTelegramChatIds) {
      final url = Uri.parse("https://api.telegram.org/bot$kTelegramBotToken/sendMessage")
          .replace(queryParameters: {
        'chat_id': chatId,
        'text': message,
      });
      try {
        final response = await http.get(url).timeout(const Duration(seconds: 10));
        final data = jsonDecode(response.body);
        debugPrint("[Telegram] $chatId -> ${data['ok']}");
        if (data['ok'] != true) allSucceeded = false;
      } catch (e) {
        debugPrint("[Telegram] Error sending to $chatId: $e");
        allSucceeded = false;
      }
    }
    return allSucceeded;
  }

  // ── FAST2SMS API CALL — second channel (used if WhatsApp fails) ──────────
  Future<bool> _sendAutoSms(String message) async {
    if (kFast2SmsApiKey == "PASTE_YOUR_NEW_FAST2SMS_API_KEY_HERE") {
      debugPrint("[SMS] API key not configured!");
      return false;
    }

    final numbers = kEmergencyContacts.join(',');
    final url = Uri.parse("https://www.fast2sms.com/dev/bulkV2").replace(
      queryParameters: {
        'authorization': kFast2SmsApiKey,
        'message': message,
        'language': 'english',
        'route': 'q',          // Quick SMS route — no DLT needed
        'numbers': numbers,
      },
    );

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      debugPrint("[SMS] Response: ${response.body}");
      final data = jsonDecode(response.body);
      return data['return'] == true;
    } catch (e) {
      debugPrint("[SMS] Error: $e");
      return false;
    }
  }

  // ── NEAREST HOSPITAL FINDER (using OpenStreetMap Overpass API — free) ────
  Future<void> _fetchNearbyHospitals(double lat, double lng) async {
    if (mounted) setState(() => _loadingHospitals = true);

    try {
      // Overpass API — free, no key needed, searches hospitals within 5km
      final query = '''
        [out:json];
        node["amenity"="hospital"](around:5000,$lat,$lng);
        out body 5;
      ''';
      final url = Uri.parse("https://overpass-api.de/api/interpreter");
      final response = await http
          .post(url, body: {'data': query})
          .timeout(const Duration(seconds: 12));

      final data = jsonDecode(response.body);
      final elements = data['elements'] as List;

      final hospitals = elements.map((e) {
        final name = e['tags']?['name'] ?? 'Hospital';
        final hLat = e['lat'] as double;
        final hLng = e['lon'] as double;
        final distKm = Geolocator.distanceBetween(lat, lng, hLat, hLng) / 1000;
        return _Hospital(name: name, lat: hLat, lng: hLng, distanceKm: distKm);
      }).toList();

      hospitals.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

      if (mounted) {
        setState(() {
          _hospitals = hospitals.take(3).toList();
          _loadingHospitals = false;
        });
      }
    } catch (e) {
      debugPrint("[HOSPITAL] Error: $e");
      if (mounted) setState(() => _loadingHospitals = false);
    }
  }

  // ── CANCEL SOS ────────────────────────────────────────────────────────────
  Future<void> _cancelSOS() async {
    setState(() => _sosActive = false);
    _setStatus("SOS cancelled. Monitoring...");
    if (_ackChar != null && _bleConnected) {
      try {
        await _ackChar!.write(utf8.encode("CANCEL"), withoutResponse: false);
      } catch (e) {
        debugPrint("[BLE] CANCEL error: $e");
      }
    }
  }

  // ── OPEN MAPS ─────────────────────────────────────────────────────────────
  Future<void> _openMaps([double? lat, double? lng]) async {
    final useLat = lat ?? _lat;
    final useLng = lng ?? _lng;
    if (useLat == null || useLng == null) return;

    final gMapsApp = Uri.parse("google.navigation:q=$useLat,$useLng");
    final gMapsBrowser = Uri.parse(
        "https://www.google.com/maps/search/?api=1&query=$useLat,$useLng");

    try {
      if (await canLaunchUrl(gMapsApp)) {
        await launchUrl(gMapsApp, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(gMapsBrowser, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      await launchUrl(gMapsBrowser, mode: LaunchMode.platformDefault);
    }
  }

  // ── DISCONNECT ────────────────────────────────────────────────────────────
  Future<void> _disconnect() async {
    _notifySub?.cancel();
    await _device?.disconnect();
    if (mounted) {
      setState(() {
        _bleConnected = false;
        _sosChar = null;
        _ackChar = null;
        _connectedSince = null;
      });
      _setStatus("Disconnected.");
    }
  }

  // ── TEST SOS ──────────────────────────────────────────────────────────────
  Future<void> _testSOS() async {
    setState(() {
      _sosActive   = true;
      _smsSent     = false;
      _alertChannel = "";
      _locationStr = "Fetching GPS...";
      _lat = null;
      _lng = null;
      _hospitals = [];
      _lastEvent = "Test at ${TimeOfDay.now().format(context)}";
    });
    _setStatus("🧪 Test SOS — sending automatically...");
    await _triggerAutomaticSOS();
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _statusMsg = msg);
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_sosActive) ...[
                _SosBanner(
                  locationStr: _locationStr,
                  smsSending: _smsSending,
                  smsSent: _smsSent,
                  alertChannel: _alertChannel,
                  onCancel: _cancelSOS,
                  onOpenMap: () => _openMaps(),
                ),
                const SizedBox(height: 16),
              ],
              if (_sosActive && (_hospitals.isNotEmpty || _loadingHospitals)) ...[
                _buildHospitalCard(),
                const SizedBox(height: 16),
              ],
              _buildStatusCard(),
              const SizedBox(height: 16),
              _bleConnected
                  ? _buildConnectedButtons()
                  : _buildConnectButton(),
              const SizedBox(height: 12),
              // TEMP DEBUG BUTTON — test SOS flow without helmet connected
              // Remove this block once helmet testing works
              OutlinedButton.icon(
                onPressed: _testSOS,
                icon: const Icon(Icons.bug_report, color: Colors.amber, size: 18),
                label: const Text("[DEBUG] Test SOS without helmet",
                    style: TextStyle(color: Colors.amber, fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.amber.withOpacity(0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 24),
              _buildHowItWorksCard(),
              const SizedBox(height: 16),
              _buildContactsCard(),
              const SizedBox(height: 16),
              _buildApiKeyWarning(),
              const SizedBox(height: 16),
              _buildWarningCard(),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF1A1A1A),
      elevation: 0,
      title: const Row(children: [
        Icon(Icons.shield_rounded, color: Color(0xFFE53935), size: 26),
        SizedBox(width: 10),
        Text("SmartHelmet",
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20)),
      ]),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(children: [
            Icon(Icons.circle,
                size: 10,
                color: _bleConnected ? Colors.green : Colors.grey),
            const SizedBox(width: 6),
            Text(
              _bleConnected ? "Connected" : "Offline",
              style: TextStyle(
                  color: _bleConnected ? Colors.green : Colors.grey,
                  fontSize: 12),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _bleConnected
              ? Colors.green.withOpacity(0.6)
              : Colors.grey.withOpacity(0.25),
          width: 1.5,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            _bleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _bleConnected ? Colors.green : Colors.grey,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            _bleConnected ? "Helmet Connected" : "Helmet Not Connected",
            style: TextStyle(
                color: _bleConnected ? Colors.green : Colors.grey,
                fontWeight: FontWeight.bold,
                fontSize: 14),
          ),
        ]),
        const SizedBox(height: 12),
        Text(_statusMsg,
            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.6)),
        if (_scanning) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: const LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: Color(0xFF2A2A2A),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF1565C0)),
            ),
          ),
        ],
        if (_connectedSince != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.timer_outlined, size: 12, color: Colors.grey),
            const SizedBox(width: 4),
            Text(
                "Ride time: "
                "${DateTime.now().difference(_connectedSince!).inMinutes} min",
                style: TextStyle(color: Colors.grey[600], fontSize: 11)),
          ]),
        ],
        if (_lastEvent != "None") ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.access_time, size: 12, color: Colors.grey),
            const SizedBox(width: 4),
            Text("Last event: $_lastEvent",
                style: TextStyle(color: Colors.grey[600], fontSize: 11)),
          ]),
        ],
      ]),
    );
  }

  Widget _buildConnectButton() {
    return ElevatedButton.icon(
      onPressed: _scanning ? null : _startScan,
      icon: _scanning
          ? const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
          : const Icon(Icons.bluetooth_searching),
      label: Text(_scanning ? "Scanning (15s)..." : "Connect to SmartHelmet"),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF0D47A1),
        padding: const EdgeInsets.symmetric(vertical: 16),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildConnectedButtons() {
    return Column(children: [
      ElevatedButton.icon(
        onPressed: _testSOS,
        icon: const Icon(Icons.warning_amber_rounded, size: 20),
        label: const Text("Test SOS (sends automatically)"),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFE53935),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 15),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: _disconnect,
        icon: const Icon(Icons.bluetooth_disabled, color: Colors.grey, size: 18),
        label: const Text("Disconnect", style: TextStyle(color: Colors.grey)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey.withOpacity(0.5)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    ]);
  }

  Widget _buildHospitalCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.local_hospital, color: Colors.greenAccent, size: 20),
          SizedBox(width: 8),
          Text("Nearest Hospitals",
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        ]),
        const SizedBox(height: 12),
        if (_loadingHospitals)
          const Center(
              child: Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: CircularProgressIndicator(strokeWidth: 2),
          ))
        else if (_hospitals.isEmpty)
          const Text("No hospitals found nearby.",
              style: TextStyle(color: Colors.grey, fontSize: 13))
        else
          ..._hospitals.map((h) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: InkWell(
              onTap: () => _openMaps(h.lat, h.lng),
              child: Row(children: [
                const Icon(Icons.local_hospital_outlined,
                    color: Colors.greenAccent, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(h.name,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
                Text("${h.distanceKm.toStringAsFixed(1)} km",
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
            ),
          )),
      ]),
    );
  }

  Widget _buildHowItWorksCard() {
    const steps = [
      (Icons.vibration, "Helmet detects accident",
          "MPU6050: 5s vibration  |  INMP441: loud shout"),
      (Icons.bluetooth, "BLE alert sent to app",
          "ESP32 instantly notifies your phone"),
      (Icons.location_on, "GPS + nearest hospitals found",
          "Exact coordinates + 3 closest hospitals"),
      (Icons.send, "Alert sent AUTOMATICALLY",
          "WhatsApp first, then SMS, then Telegram — no tap needed"),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("How It Works",
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 14),
        ...steps.asMap().entries.map((entry) {
          final i = entry.key;
          final s = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(s.$1, color: const Color(0xFF42A5F5), size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      width: 20, height: 20,
                      decoration: const BoxDecoration(
                          color: Color(0xFF1565C0), shape: BoxShape.circle),
                      child: Center(
                        child: Text("${i + 1}",
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(s.$2,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                  ]),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 28),
                    child: Text(s.$3,
                        style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                  ),
                ]),
              ),
            ]),
          );
        }),
      ]),
    );
  }

  Widget _buildContactsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.contacts_rounded, color: Color(0xFFE53935), size: 20),
          SizedBox(width: 8),
          Text("Emergency Contacts",
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        ]),
        const SizedBox(height: 4),
        const Text("Edit kEmergencyContacts / kTelegramChatIds in main.dart to change",
            style: TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 14),
        ...kEmergencyContacts.asMap().entries.map((e) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text("${e.key + 1}",
                    style: const TextStyle(
                        color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("Contact ${e.key + 1}",
                  style: const TextStyle(color: Colors.grey, fontSize: 11)),
              Text(e.value,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
            ]),
          ]),
        )),
        const Divider(color: Color(0xFF2A2A2A)),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.person_rounded, color: Colors.grey, size: 18),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("Rider", style: TextStyle(color: Colors.grey, fontSize: 11)),
            Text(kRiderName,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
          ]),
        ]),
      ]),
    );
  }

  Widget _buildApiKeyWarning() {
    final whatsappConfigured =
        kWhatsScaleApiKey != "PASTE_YOUR_WHATSSCALE_API_KEY_HERE";
    final telegramConfigured =
        kTelegramBotToken != "PASTE_YOUR_NEW_TELEGRAM_BOT_TOKEN_HERE";
    final smsConfigured = kFast2SmsApiKey != "PASTE_YOUR_NEW_FAST2SMS_API_KEY_HERE";
    final configuredCount =
        [whatsappConfigured, telegramConfigured, smsConfigured].where((c) => c).length;

    String message;
    Color color;
    IconData icon;
    if (configuredCount == 3) {
      message = "WhatsApp (primary) + Telegram + SMS (fallbacks) all configured ✓";
      color = Colors.green;
      icon = Icons.check_circle;
    } else if (configuredCount == 2) {
      message = "2 of 3 channels configured — one fallback is missing. "
          "Check WhatsApp/Telegram/SMS keys above.";
      color = Colors.orange;
      icon = Icons.warning_amber_rounded;
    } else if (configuredCount == 1) {
      message = "⚠️ Only 1 of 3 alert channels configured — SOS reliability is low.";
      color = Colors.orange;
      icon = Icons.warning_amber_rounded;
    } else {
      message = "⚠️ No alert channels configured — SOS will NOT send automatically!";
      color = Colors.red;
      icon = Icons.error_outline;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: TextStyle(color: color, fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _buildWarningCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1.2),
      ),
      child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.info_outline_rounded, color: Colors.orange, size: 18),
          SizedBox(width: 8),
          Text("Before Riding",
              style: TextStyle(
                  color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13)),
        ]),
        SizedBox(height: 10),
        Text(
          "① Keep this app open in foreground\n"
          "② Keep screen ON — disable auto lock\n"
          "③ Do NOT pair SmartHelmet from Bluetooth Settings\n"
          "④ SOS sends automatically — no tap needed\n"
          "⑤ Phone needs mobile data/WiFi for Telegram/SMS + hospitals\n"
          "⑥ Emergency contacts must message the Telegram bot and tap START at least once",
          style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.8),
        ),
      ]),
    );
  }
}

// ============================================================================
// HOSPITAL MODEL
// ============================================================================
class _Hospital {
  final String name;
  final double lat, lng, distanceKm;
  _Hospital({required this.name, required this.lat, required this.lng, required this.distanceKm});
}

// ============================================================================
// SOS EMERGENCY BANNER
// ============================================================================
class _SosBanner extends StatelessWidget {
  final String locationStr;
  final bool smsSending, smsSent;
  final String alertChannel;
  final VoidCallback onCancel, onOpenMap;
  const _SosBanner({
    required this.locationStr,
    required this.smsSending,
    required this.smsSent,
    required this.alertChannel,
    required this.onCancel,
    required this.onOpenMap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFB71C1C), Color(0xFFE53935)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.red.withOpacity(0.5), blurRadius: 24, spreadRadius: 2),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.emergency_rounded, color: Colors.white, size: 26),
          SizedBox(width: 10),
          Text("EMERGENCY ACTIVE",
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          if (smsSending)
            const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          else
            Icon(smsSent ? Icons.check_circle : Icons.error_outline,
                color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(
            smsSending
                ? "Sending SOS automatically..."
                : (smsSent
                    ? "SOS sent automatically via $alertChannel ✓"
                    : "SOS send failed (Telegram + SMS)"),
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.location_on, color: Colors.white60, size: 14),
          const SizedBox(width: 4),
          Expanded(
            child: Text(locationStr,
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: onOpenMap,
              icon: const Icon(Icons.map_rounded, size: 16),
              label: const Text("View on Map"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFFB71C1C),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text("I'm OK"),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white, width: 1.5),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}