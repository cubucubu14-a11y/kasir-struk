import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:permission_handler/permission_handler.dart';

// ================== KONFIGURASI ==================
const String WEB_APP_URL = 'https://script.google.com/macros/s/AKfycbzDJ-JitJE3DTayj-Kgyq1gJD0_IK6w9ZvS7V3RznUYFUV22qHFY6_oW-nkfq300yU/exec';
const String API_KEY = 'cireng-woi-secret-2026';
const List<String> KASIR_OPTIONS = [
  'Kasir 01','Kasir 02','Kasir 03','Kasir 04','Kasir 05',
  'Kasir 06','Kasir 07','Kasir 08','Kasir 09','Kasir 10',
];

// ================== WARNA ==================
class C {
  static const bg = Color(0xFF0F172A);
  static const card = Color(0xFF1E293B);
  static const cardLight = Color(0xFF334155);
  static const neon = Color(0xFFB9FF66);
  static const blueBtn = Color(0xFFA9D1F9);
  static const muted = Color(0xFF94A3B8);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF97316);
}

// ================== FORMAT ==================
final rupiah = NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);
final tglJam = DateFormat('dd-MM-yyyy HH:mm');
final tglOnly = DateFormat('dd-MM-yyyy');

// ================== HELPER POST (HANDLE 302 REDIRECT) ==================
Future<http.Response> _apiPost(Map<String, dynamic> body) async {
  final client = http.Client();
  try {
    final req = http.Request('POST', Uri.parse(WEB_APP_URL))
      ..headers['Content-Type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode(body)
      ..followRedirects = false;

    final streamed = await client.send(req).timeout(const Duration(seconds: 30));
    var res = await http.Response.fromStream(streamed);

    if (res.statusCode == 302 || res.statusCode == 301 || res.statusCode == 303) {
      final loc = res.headers['location'];
      if (loc != null) {
        return await client.get(Uri.parse(loc)).timeout(const Duration(seconds: 30));
      }
    }
    return res;
  } finally {
    client.close();
  }
}

// ================== MODEL ==================
class MenuItem {
  String id;
  String nama;
  int harga;
  String status;
  MenuItem({required this.id, required this.nama, required this.harga, required this.status});
  factory MenuItem.fromJson(Map<String, dynamic> j) =>
      MenuItem(id: j['id'].toString(), nama: j['nama'], harga: j['harga'], status: j['status']);
  Map<String, dynamic> toJson() => {'id': id, 'nama': nama, 'harga': harga, 'status': status};
}

class CartItem {
  final String menuId;
  final String nama;
  final int harga;
  int qty;
  CartItem({required this.menuId, required this.nama, required this.harga, this.qty = 1});
}

// ================== MAIN ==================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('trx');
  await Hive.openBox('cache');
  await Hive.openBox('menus_local');
  runApp(const CirengApp());
}

class CirengApp extends StatelessWidget {
  const CirengApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cireng Woi POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: C.bg),
      home: const SplashRouter(),
    );
  }
}

// ================== SPLASH ROUTER ==================
class SplashRouter extends StatefulWidget {
  const SplashRouter({super.key});
  @override
  State<SplashRouter> createState() => _SplashRouterState();
}

class _SplashRouterState extends State<SplashRouter> {
  bool loading = true;
  String? cabang;
  String? kasir;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      cabang = p.getString('cabang');
      kasir = p.getString('kasir');
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: C.neon)));
    if (cabang == null || kasir == null) return const SetupScreen();
    return KasirScreen(cabang: cabang!, kasir: kasir!);
  }
}

// ================== SETUP SCREEN ==================
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final Set<String> taken = {};
  final ctrlCabang = TextEditingController();
  String? selectedKasir;
  bool loading = true;
  bool isRestoring = false;
  String restoreText = '';
  String error = '';

  @override
  void initState() { super.initState(); _fetchTaken(); }

  Future<void> _fetchTaken() async {
    try {
      final res = await http.get(Uri.parse('$WEB_APP_URL?action=listTakenKasirs'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        taken.addAll(List<String>.from(data['kasirs'] ?? []));
      }
    } catch (_) {
      error = 'Gagal memuat data kasir. Cek koneksi.';
    }
    setState(() => loading = false);
  }

  void _onKasirTap(String kasir) {
    if (!taken.contains(kasir)) {
      setState(() => selectedKasir = kasir);
      return;
    }
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: Text('$kasir Sudah Terpakai'),
      content: const Text('Apakah ini HP Anda?\n\nJika ya, data 7 hari terakhir akan dimuat ke HP ini.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Batal'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () {
            Navigator.pop(context);
            setState(() => selectedKasir = kasir);
          },
          child: const Text('Ya, Ini HP Saya'),
        ),
      ],
    ));
  }

  Future<void> _confirm() async {
    final cab = ctrlCabang.text.trim();
    if (cab.isEmpty) { setState(() => error = 'Nama cabang wajib diisi'); return; }
    if (selectedKasir == null) { setState(() => error = 'Pilih kasir dulu'); return; }

    final p = await SharedPreferences.getInstance();
    await p.setString('cabang', cab);
    await p.setString('kasir', selectedKasir!);

    final boxTrx = Hive.box('trx');
    final hasDataLokal = boxTrx.values.whereType<Map>()
        .any((e) => e['cabang'] == cab);

    if (!hasDataLokal) {
      await _autoRestore(cab);
    }

    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => KasirScreen(cabang: cab, kasir: selectedKasir!)));
  }

  Future<void> _autoRestore(String cab) async {
    setState(() { isRestoring = true; restoreText = 'Memuat data...'; });
    final boxTrx = Hive.box('trx');
    final boxMenus = Hive.box('menus_local');
    try {
      final res = await _apiPost({
        'token': API_KEY, 'action': 'restore7Days', 'cabang': cab,
      });

      if (res.statusCode == 200) {
        final r = jsonDecode(res.body);
        if (r['status'] == 'success') {
          final list = List<Map<String, dynamic>>.from(r['transactions'] ?? []);
          for (int i = 0; i < list.length; i++) {
            final item = list[i];
            if (mounted) setState(() => restoreText = 'Memuat ${i+1}/${list.length}...');
            final id = item['id'];
            if (!boxTrx.containsKey(id)) {
              await boxTrx.put(id, {
                'id': id, 'cabang': cab, 'time': item['time'],
                'kasir': item['kasir'], 'method': item['method'],
                'status': item['status'],
                'amount': (item['amount'] as num).toInt(),
                'detail': item['detail'] ?? '', 'pending': 'none',
              });
            }
          }
          final menuList = List<Map<String, dynamic>>.from(r['menu'] ?? []);
          for (final item in menuList) {
            final id = item['id'].toString();
            if (!boxMenus.containsKey(id)) {
              await boxMenus.put(id, {
                'id': id, 'nama': item['nama'],
                'harga': item['harga'], 'status': item['status'],
                'pending': false,
              });
            }
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() { isRestoring = false; restoreText = ''; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: loading
                ? const CircularProgressIndicator(color: C.neon)
                : isRestoring
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('CIRENG WOII',
                            style: TextStyle(color: C.neon, fontSize: 32, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 24),
                        const CircularProgressIndicator(color: C.neon),
                        const SizedBox(height: 16),
                        Text(restoreText, style: const TextStyle(color: C.muted)),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text('CIRENG WOII',
                            style: TextStyle(color: C.neon, fontSize: 32, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 24),
                        const Text('Nama Cabang', style: TextStyle(color: C.muted, fontSize: 12)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: ctrlCabang,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            hintText: 'Contoh: Cabang A',
                            filled: true, fillColor: C.card,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Pilih Kasir', style: TextStyle(color: C.muted, fontSize: 12)),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(10)),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: selectedKasir,
                              isExpanded: true, dropdownColor: C.card,
                              hint: const Text('-- Pilih Kasir --'),
                              items: KASIR_OPTIONS.map((k) {
                                final isTaken = taken.contains(k);
                                return DropdownMenuItem(
                                  value: k,
                                  child: Text(isTaken ? '$k (Terpakai)' : k,
                                      style: TextStyle(color: isTaken ? Colors.grey : Colors.white)),
                                );
                              }).toList(),
                              onChanged: (v) {
                                if (v == null) return;
                                _onKasirTap(v);
                              },
                            ),
                          ),
                        ),
                        if (error.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(error, style: const TextStyle(color: C.danger, fontSize: 12)),
                        ],
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: C.neon, foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: _confirm,
                            child: const Text('MULAI', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          ),
                        ),
                      ]),
          ),
        ),
      ),
    );
  }
}

// ================== KASIR SCREEN ==================
class KasirScreen extends StatefulWidget {
  final String cabang;
  final String kasir;
  const KasirScreen({required this.cabang, required this.kasir, super.key});
  @override
  State<KasirScreen> createState() => _KasirScreenState();
}

class _KasirScreenState extends State<KasirScreen> {
  final boxTrx = Hive.box('trx');
  final boxCache = Hive.box('cache');
  final boxMenus = Hive.box('menus_local');

  bool isSyncing = false;
  bool isRevealed = false;
  int pendingCount = 0;

  String syncText = '';
  bool isCekHantu = false;
  String cekHantuText = '';

  final List<CartItem> cart = [];
  List<MenuItem> menus = [];
  String filterMode = 'today';
  DateTimeRange? customRange;
  final BlueThermalPrinter printer = BlueThermalPrinter.instance;

  @override
  void initState() {
    super.initState();
    _loadMenus();
    _updatePending();
    _pullToday();
  }

  // ===== LOAD MENUS (SELALU RELOAD) =====
  Future<void> _loadMenus() async {
    final list = boxMenus.values
        .whereType<Map>()
        .where((e) => e['pendingDelete'] != true)
        .map((e) => MenuItem(
          id: e['id'].toString(),
          nama: e['nama'].toString(),
          harga: (e['harga'] as num).toInt(),
          status: e['status'].toString(),
        ))
        .toList();
    if (mounted) setState(() => menus = list);
    _refreshMenuBackground();
  }

  Future<void> _refreshMenuBackground() async {
    try {
      final res = await http.get(Uri.parse('$WEB_APP_URL?action=getMenu'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = List<Map<String, dynamic>>.from(data['data'] ?? []);
        bool changed = false;
        for (final item in list) {
          final id = item['id'].toString();
          if (!boxMenus.containsKey(id)) {
            await boxMenus.put(id, {
              'id': id, 'nama': item['nama'], 'harga': item['harga'],
              'status': item['status'], 'pending': false,
            });
            changed = true;
          }
        }
        if (changed && mounted) {
          final merged = boxMenus.values
              .whereType<Map>()
              .where((e) => e['pendingDelete'] != true)
              .map((e) => MenuItem(
                id: e['id'].toString(),
                nama: e['nama'].toString(),
                harga: (e['harga'] as num).toInt(),
                status: e['status'].toString(),
              ))
              .toList();
          setState(() => menus = merged);
        }
      }
    } catch (_) {}
  }

  // ===== FILTER =====
  DateTime get _startDate {
    final now = DateTime.now();
    switch (filterMode) {
      case 'today': return DateTime(now.year, now.month, now.day);
      case 'yesterday':
        final y = now.subtract(const Duration(days: 1));
        return DateTime(y.year, y.month, y.day);
      case 'month': return DateTime(now.year, now.month, 1);
      case 'custom': return customRange?.start ?? now;
    }
    return now;
  }

  DateTime get _endDate {
    final now = DateTime.now();
    switch (filterMode) {
      case 'today': return DateTime(now.year, now.month, now.day, 23, 59, 59);
      case 'yesterday':
        final y = now.subtract(const Duration(days: 1));
        return DateTime(y.year, y.month, y.day, 23, 59, 59);
      case 'month': return DateTime(now.year, now.month, now.day, 23, 59, 59);
      case 'custom':
        final e = customRange?.end ?? now;
        return DateTime(e.year, e.month, e.day, 23, 59, 59);
    }
    return now;
  }

  bool get isTodayFilter => filterMode == 'today';

  List<Map<String, dynamic>> get _trxList {
    return boxTrx.values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((t) => t['cabang'] == widget.cabang)
        .where((t) => t['pending'] != 'delete')
        .where((t) {
          try {
            final dt = tglJam.parse(t['time']);
            return !dt.isBefore(_startDate) && !dt.isAfter(_endDate);
          } catch (_) { return false; }
        })
        .toList()
      ..sort((a, b) => (b['time'] as String).compareTo(a['time'] as String));
  }

  int get _total => _trxList.fold(0, (s, t) => s + (t['amount'] as int));
  int get _totalTunai => _trxList.where((t) => t['method'] == 'Tunai').fold(0, (s, t) => s + (t['amount'] as int));
  int get _totalQris => _trxList.where((t) => t['method'] == 'QRIS').fold(0, (s, t) => s + (t['amount'] as int));

  void _updatePending() {
    final p = boxTrx.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e))
        .where((t) => t['pending'] != 'none').length;
    if (mounted) setState(() => pendingCount = p);
  }

  // ===== PULL TODAY =====
  Future<void> _pullToday() async {
    try {
      final res = await http.get(Uri.parse(
        '$WEB_APP_URL?action=pullToday&cabang=${Uri.encodeComponent(widget.cabang)}'
      )).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = List<Map<String, dynamic>>.from(data['data'] ?? []);
        for (final item in list) {
          final id = item['id'];
          if (!boxTrx.containsKey(id)) {
            await boxTrx.put(id, {
              'id': id, 'cabang': widget.cabang, 'time': item['time'],
              'kasir': item['kasir'], 'method': item['method'], 'status': item['status'],
              'amount': (item['amount'] as num).toInt(), 'detail': item['detail'] ?? '',
              'pending': 'none',
            });
          }
        }
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  // ===== SYNC (BATCH + MENU PENDING) =====
  Future<void> _syncPending() async {
    if (isSyncing || isCekHantu) return;
    final cab = widget.cabang;
    final pending = boxTrx.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e))
        .where((t) => t['cabang'] == cab && t['pending'] != 'none').toList();

    setState(() {
      isSyncing = true;
      syncText = pending.isEmpty ? 'Menarik data...' : '0/${pending.length} data';
    });

    int pushed = 0;
    try {
      final ops = pending.map((t) => {
        'action': t['pending'],
        'data': {
          'id': t['id'], 'time': t['time'], 'kasir': t['kasir'],
          'method': t['method'], 'status': t['status'],
          'amount': t['amount'], 'detail': t['detail'] ?? '',
        }
      }).toList();

      for (int i = 0; i < pending.length; i++) {
        if (mounted) setState(() => syncText = '${i+1}/${pending.length} data');
        await Future.delayed(const Duration(milliseconds: 80));
      }

      final res = await _apiPost({
        'token': API_KEY, 'action': 'syncAndPull',
        'cabang': cab, 'operations': ops,
      });

      if (res.statusCode == 200) {
        final r = jsonDecode(res.body);
        if (r['status'] == 'success') {
          for (final t in pending) {
            if (t['pending'] == 'delete') { await boxTrx.delete(t['id']); }
            else {
              final u = Map<String, dynamic>.from(t);
              u['pending'] = 'none';
              await boxTrx.put(t['id'], u);
            }
          }
          pushed = r['pushed'] ?? pending.length;

          final list = List<Map<String, dynamic>>.from(r['transactions'] ?? []);
          for (int i = 0; i < list.length; i++) {
            final item = list[i];
            if (mounted) setState(() => syncText = 'Menyimpan ${i+1}/${list.length}...');
            final id = item['id'];
            if (!boxTrx.containsKey(id)) {
              await boxTrx.put(id, {
                'id': id, 'cabang': cab, 'time': item['time'],
                'kasir': item['kasir'], 'method': item['method'],
                'status': item['status'],
                'amount': (item['amount'] as num).toInt(),
                'detail': item['detail'] ?? '', 'pending': 'none',
              });
            }
          }

          final menuList = List<Map<String, dynamic>>.from(r['menu'] ?? []);
          for (final item in menuList) {
            final id = item['id'].toString();
            if (!boxMenus.containsKey(id)) {
              await boxMenus.put(id, {
                'id': id, 'nama': item['nama'],
                'harga': item['harga'], 'status': item['status'],
                'pending': false,
              });
            }
          }
        }
      }

      // PUSH MENU PENDING
      final pendingMenus = boxMenus.values
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => e['pending'] == true)
          .toList();

      for (int i = 0; i < pendingMenus.length; i++) {
        final m = pendingMenus[i];
        final mid = m['id'].toString();
        if (mounted) setState(() => syncText = 'Menu ${i+1}/${pendingMenus.length}...');

        try {
          if (m['pendingDelete'] == true) {
            final r = await _apiPost({'token': API_KEY, 'action': 'deleteMenu', 'id': mid});
            if (r.statusCode == 200) {
              final rr = jsonDecode(r.body);
              if (rr['status'] == 'success') await boxMenus.delete(mid);
            }
          } else {
            final r = await _apiPost({
              'token': API_KEY, 'action': 'saveMenu',
              'menu': {'id': mid, 'nama': m['nama'], 'harga': m['harga'], 'status': m['status']},
            });
            if (r.statusCode == 200) {
              final rr = jsonDecode(r.body);
              if (rr['status'] == 'success') {
                m['pending'] = false;
                m['pendingDelete'] = false;
                await boxMenus.put(mid, m);
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {}

    _updatePending();
    await _refreshMenuBackground();
    // RELOAD menus list juga (yang sudah difilter pendingDelete)
    final merged = boxMenus.values
        .whereType<Map>()
        .where((e) => e['pendingDelete'] != true)
        .map((e) => MenuItem(
          id: e['id'].toString(),
          nama: e['nama'].toString(),
          harga: (e['harga'] as num).toInt(),
          status: e['status'].toString(),
        ))
        .toList();
    if (mounted) setState(() => menus = merged);

    if (mounted) {
      setState(() { isSyncing = false; syncText = ''; });
    }
    _snack(pushed > 0
        ? '✅ $pushed data dikirim + data ditarik'
        : '✅ Data ditarik dari Sheets');
  }

  // ===== CEK DATA HANTU =====
  Future<void> _cekHantu() async {
    if (isSyncing || isCekHantu) return;
    setState(() { isCekHantu = true; cekHantuText = 'Memeriksa transaksi...'; });

    final localIds = boxTrx.values.whereType<Map>().map((e) => Map<String, dynamic>.from(e))
        .where((t) => t['cabang'] == widget.cabang).map((t) => t['id'].toString()).toList();
    final localMenuIds = boxMenus.values.whereType<Map>().map((e) => e['id'].toString()).toList();

    try {
      final res = await _apiPost({
        'token': API_KEY, 'action': 'cekHantu',
        'cabang': widget.cabang,
        'localIds': localIds,
        'localMenuIds': localMenuIds,
      });

      setState(() => cekHantuText = 'Menghapus data hantu...');

      if (res.statusCode == 200) {
        final r = jsonDecode(res.body);
        if (r['status'] == 'success') {
          final dt = r['deletedTrx'] ?? 0;
          final dm = r['deletedMenu'] ?? 0;
          if (dt == 0 && dm == 0) {
            _snack('✅ Data bersih, tidak ada hantu');
          } else {
            _snack('✅ $dt transaksi hantu + $dm menu hantu dihapus');
          }
        } else {
          _snack('Gagal: ${r['message']}');
        }
      }
    } catch (e) { _snack('Error: $e'); }

    if (mounted) setState(() { isCekHantu = false; cekHantuText = ''; });
  }

  // ===== RESTORE 7 HARI =====
  Future<void> _restore7Days() async {
    if (isSyncing || isCekHantu) return;
    setState(() { isSyncing = true; syncText = 'Memuat data...'; });

    try {
      final res = await _apiPost({
        'token': API_KEY, 'action': 'restore7Days',
        'cabang': widget.cabang,
      });

      if (res.statusCode == 200) {
        final r = jsonDecode(res.body);
        if (r['status'] == 'success') {
          final list = List<Map<String, dynamic>>.from(r['transactions'] ?? []);
          int added = 0;
          for (int i = 0; i < list.length; i++) {
            final item = list[i];
            if (mounted) setState(() => syncText = 'Memuat ${i+1}/${list.length}...');
            final id = item['id'];
            if (!boxTrx.containsKey(id)) {
              await boxTrx.put(id, {
                'id': id, 'cabang': widget.cabang, 'time': item['time'],
                'kasir': item['kasir'], 'method': item['method'],
                'status': item['status'],
                'amount': (item['amount'] as num).toInt(),
                'detail': item['detail'] ?? '', 'pending': 'none',
              });
              added++;
            }
          }

          final menuList = List<Map<String, dynamic>>.from(r['menu'] ?? []);
          for (final item in menuList) {
            final id = item['id'].toString();
            if (!boxMenus.containsKey(id)) {
              await boxMenus.put(id, {
                'id': id, 'nama': item['nama'],
                'harga': item['harga'], 'status': item['status'],
                'pending': false,
              });
            }
          }

          _snack('✅ $added transaksi + menu dimuat');
        } else {
          _snack('Gagal: ${r['message']}');
        }
      }
    } catch (e) { _snack('Error: $e'); }

    _updatePending();
    await _refreshMenuBackground();
    if (mounted) setState(() { isSyncing = false; syncText = ''; });
  }

  // ===== KERANJANG =====
  void _addToCart(MenuItem menu, [int? customHarga]) {
    final harga = customHarga ?? menu.harga;
    final key = '${menu.id}_$harga';
    final idx = cart.indexWhere((c) => '${c.menuId}_${c.harga}' == key);
    setState(() {
      if (idx >= 0) { cart[idx].qty++; }
      else { cart.add(CartItem(menuId: menu.id, nama: menu.nama, harga: harga)); }
    });
  }

  void _removeFromCart(int idx) => setState(() => cart.removeAt(idx));
  String get _cartTotal => rupiah.format(cart.fold(0, (s, c) => s + c.harga * c.qty));

  // ===== SAVE TRANSAKSI =====
  Future<void> _saveTransaction(String method) async {
    final total = cart.fold(0, (s, c) => s + c.harga * c.qty);
    final detail = cart.map((c) => '${c.nama} ${c.qty}x@${c.harga}').join(', ');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final kNum = widget.kasir.replaceAll(RegExp(r'[^0-9]'), '');
    final id = '$ts-$kNum';
    final now = DateTime.now();

    await boxTrx.put(id, {
      'id': id, 'cabang': widget.cabang, 'time': tglJam.format(now),
      'kasir': widget.kasir, 'method': method, 'status': 'Sukses',
      'amount': total, 'detail': detail, 'pending': 'create',
    });

    setState(() => cart.clear());
    _updatePending();
    if (mounted) _showPrintDialog(detail, total, method, now, id);
    _syncPending();
  }

  void _showPrintDialog(String detail, int total, String method, DateTime time, String id) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Transaksi Tersimpan'),
      content: const Text('Cetak struk?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tidak')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () { Navigator.pop(context); _printStruk(detail, total, method, time); },
          child: const Text('Cetak'),
        ),
      ],
    ));
  }

  // ===== PRINT =====
  Future<void> _printStruk(String detail, int total, String method, DateTime time) async {
    try {
      final p = await SharedPreferences.getInstance();
      final mac = p.getString('printer_mac');
      if (mac == null) { _snack('Printer belum diatur'); return; }
      final connected = await printer.isConnected ?? false;
      if (!connected) {
        final devices = await printer.getBondedDevices();
        final device = devices.firstWhere((d) => d.address == mac, orElse: () => devices.first);
        await printer.connect(device);
      }
      final namaToko = p.getString('toko_nama') ?? 'CIRENG WOII';
      final alamat = p.getString('toko_alamat') ?? '';
      final telp = p.getString('toko_telp') ?? '';
      final footer = p.getString('toko_footer') ?? 'Terima kasih :)';
      final promo = p.getString('toko_promo') ?? '';
      final kasirNum = widget.kasir.replaceAll(RegExp(r'[^0-9]'), '');
      final tgl = DateFormat('dd-MM-yy HH:mm').format(time);

      String line(String kiri, String kanan, {int width = 32}) {
        final space = width - kiri.length - kanan.length;
        return kiri + (space > 0 ? ' ' * space : ' ') + kanan;
      }

      await printer.printNewLine();
      await printer.printCustom(namaToko, 2, 1);
      if (alamat.isNotEmpty) await printer.printCustom(alamat, 1, 1);
      if (telp.isNotEmpty) await printer.printCustom('Telp: $telp', 1, 1);
      await printer.printCustom('================================', 1, 1);
      await printer.printCustom('$tgl    $kasirNum    $method', 1, 0);
      await printer.printCustom('--------------------------------', 1, 1);
      for (final item in detail.split(', ')) {
        await printer.printCustom(item, 1, 0);
      }
      await printer.printCustom('--------------------------------', 1, 1);
      await printer.printCustom(line('TOTAL', rupiah.format(total)), 1, 1);
      await printer.printCustom('================================', 1, 1);
      await printer.printCustom(footer, 1, 1);
      if (promo.isNotEmpty) {
        await printer.printCustom('--------------------------------', 1, 1);
        await printer.printCustom(promo, 1, 1);
      }
      await printer.printCustom('================================', 1, 1);
      await printer.printNewLine();
      await printer.printNewLine();
      await printer.paperCut();
    } catch (e) { _snack('Gagal cetak: $e'); }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ===== EDIT / HAPUS =====
  Future<void> _editTrx(String id, int newAmount, String newMethod) async {
    final t = Map<String, dynamic>.from(boxTrx.get(id));
    t['amount'] = newAmount;
    t['method'] = newMethod;
    t['pending'] = (t['pending'] == 'create') ? 'create' : 'update';
    await boxTrx.put(id, t);
    setState(() {});
    _updatePending();
    _syncPending();
  }

  Future<void> _deleteTrx(String id) async {
    final t = Map<String, dynamic>.from(boxTrx.get(id));
    if (t['pending'] == 'create') { await boxTrx.delete(id); }
    else { t['pending'] = 'delete'; await boxTrx.put(id, t); }
    setState(() {});
    _updatePending();
    _syncPending();
  }

  // ===== EXPORT CSV =====
  Future<void> _exportCsv() async {
    final trx = _trxList;
    if (trx.isEmpty) { _snack('Tidak ada data'); return; }
    final buf = StringBuffer('ID,Waktu,Kasir,Metode,Status,Nominal,Detail\n');
    for (final t in trx) {
      buf.writeln('${t['id']},${t['time']},${t['kasir']},${t['method']},${t['status']},${t['amount']},"${t['detail'] ?? ''}"');
    }
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/cireng_${widget.cabang.replaceAll(" ", "_")}_${tglOnly.format(_startDate)}.csv');
    await f.writeAsString(buf.toString());
    await Share.shareXFiles([XFile(f.path)], text: 'Laporan Cireng Woi');
  }

  void _setFilter(String mode) {
    setState(() => filterMode = mode);
    _pullToday();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context, firstDate: DateTime(2024), lastDate: now,
      initialDateRange: customRange,
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(colorScheme: const ColorScheme.dark(primary: C.neon, onPrimary: Colors.black)),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() { customRange = picked; filterMode = 'custom'; });
      _pullToday();
    }
  }

  String get _filterLabel {
    switch (filterMode) {
      case 'today': return 'Hari Ini';
      case 'yesterday': return 'Kemarin';
      case 'month': return 'Bulan Ini';
      case 'custom':
        if (customRange != null) return '${tglOnly.format(customRange!.start)} - ${tglOnly.format(customRange!.end)}';
        return 'Pilih Tanggal';
    }
    return 'Hari Ini';
  }

  // ===== BUILD =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: cart.isEmpty ? null : FloatingActionButton.extended(
        backgroundColor: C.neon, foregroundColor: Colors.black, onPressed: _showCart,
        icon: const Icon(Icons.shopping_cart),
        label: Text('${cart.fold(0, (s, c) => s + c.qty)} | $_cartTotal',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('CIRENG WOII', style: TextStyle(color: C.neon, fontSize: 22, fontWeight: FontWeight.bold)),
                    Text('${widget.kasir} - ${widget.cabang}', style: const TextStyle(color: C.muted, fontSize: 11)),
                  ])),
                  IconButton(icon: const Icon(Icons.person, color: C.neon), onPressed: _showMenu),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GestureDetector(
                  onDoubleTap: isRevealed ? null : () => setState(() => isRevealed = true),
                  onTap: isRevealed ? () => setState(() => isRevealed = false) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: C.card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: C.neon, width: 1.2),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        if (isRevealed) _filterChip(),
                        const Spacer(),
                        _iconBtn(Icons.refresh, (isSyncing || isCekHantu) ? null : _syncPending),
                        const SizedBox(width: 2),
                        _iconBtn(Icons.search, (isSyncing || isCekHantu) ? null : _cekHantu),
                      ]),
                      Text(
                        isRevealed ? rupiah.format(_total) : 'Rp • • • • • •',
                        style: TextStyle(
                          color: C.neon,
                          fontSize: isRevealed ? 24 : 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isRevealed) ...[
                        const SizedBox(height: 2),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text('${_trxList.length} trx',
                              style: const TextStyle(color: C.muted, fontSize: 10)),
                          const SizedBox(width: 8),
                          Text('Tunai: ${rupiah.format(_totalTunai)}',
                              style: const TextStyle(color: Colors.green, fontSize: 10)),
                          const SizedBox(width: 8),
                          Text('QRIS: ${rupiah.format(_totalQris)}',
                              style: const TextStyle(color: Colors.blue, fontSize: 10)),
                        ]),
                      ],
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IgnorePointer(ignoring: !isTodayFilter,
                  child: Opacity(opacity: isTodayFilter ? 1 : 0.4,
                    child: GridView.count(
                      crossAxisCount: 2, childAspectRatio: 3.2, shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 6, crossAxisSpacing: 6,
                      children: [for (final a in [5000, 10000, 15000, 20000, 25000, 30000]) _nominalBtn(a)],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: IgnorePointer(ignoring: !isTodayFilter,
                  child: Opacity(opacity: isTodayFilter ? 1 : 0.4,
                    child: SizedBox(width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange[300], foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: _showManualInput,
                        icon: const Icon(Icons.edit, size: 18),
                        label: const Text('INPUT MANUAL', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildRiwayat()),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.neon, foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _exportCsv,
                    icon: const Icon(Icons.download),
                    label: const Text('EXPORT KE CSV', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ]),
            if (isSyncing || isCekHantu)
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(8),
                      bottomRight: Radius.circular(8),
                    ),
                  ),
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: LinearProgressIndicator(
                          backgroundColor: Colors.transparent,
                          valueColor: AlwaysStoppedAnimation<Color>(C.neon),
                        ),
                      ),
                      Center(
                        child: Text(
                          isCekHantu ? cekHantuText : syncText,
                          style: const TextStyle(
                            color: C.neon, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, color: onTap == null ? C.muted : Colors.white, size: 18),
      ),
    );
  }

  Widget _nominalBtn(int amount) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: C.blueBtn, foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () => _showMenuPicker(amount),
      child: Text(rupiah.format(amount), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
    );
  }

  Widget _filterChip() {
    return InkWell(onTap: _showFilterMenu,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: C.cardLight, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(_filterLabel, style: const TextStyle(color: Colors.white, fontSize: 11)),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
        ]),
      ));
  }

  void _showFilterMenu() {
    showModalBottomSheet(context: context, backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        _filterOption('Hari Ini', 'today'),
        _filterOption('Kemarin', 'yesterday'),
        _filterOption('Bulan Ini', 'month'),
        ListTile(
          leading: const Icon(Icons.calendar_today, color: C.neon),
          title: const Text('Pilih Tanggal...'),
          onTap: () { Navigator.pop(context); _pickRange(); },
        ),
        const SizedBox(height: 12),
      ]));
  }

  Widget _filterOption(String label, String mode) {
    return ListTile(title: Text(label),
      trailing: filterMode == mode ? const Icon(Icons.check, color: C.neon) : null,
      onTap: () { Navigator.pop(context); _setFilter(mode); });
  }

  Widget _buildRiwayat() {
    final trx = _trxList;
    if (trx.isEmpty) return const Center(child: Text('Belum ada transaksi', style: TextStyle(color: C.muted)));
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: trx.length,
      itemBuilder: (_, i) {
        final t = trx[i];
        final isMine = t['kasir'] == widget.kasir;
        final pending = t['pending'] != 'none';
        final kasirNum = (t['kasir'] as String).replaceAll(RegExp(r'[^0-9]'), '');
        final jam = (t['time'] as String).split(' ')[1];
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Icon(t['method'] == 'QRIS' ? Icons.qr_code_scanner : Icons.money,
                color: t['method'] == 'QRIS' ? Colors.blue : Colors.green, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(jam, style: const TextStyle(color: C.muted, fontSize: 12)),
                if (!isMine) ...[const SizedBox(width: 6), Text(kasirNum, style: const TextStyle(color: C.muted, fontSize: 11))],
                if (pending) ...[const SizedBox(width: 6), const Icon(Icons.sync, size: 11, color: C.warning)],
              ]),
              if ((t['detail'] as String).isNotEmpty)
                Text(t['detail'], style: const TextStyle(color: C.muted, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(rupiah.format(t['amount']), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ])),
            IconButton(icon: Icon(Icons.print, size: 18, color: isMine ? C.muted : C.muted.withOpacity(0.3)),
                onPressed: isMine ? () => _printUlang(t) : null, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            const SizedBox(width: 4),
            IconButton(icon: Icon(Icons.edit, size: 18, color: isMine ? Colors.lightBlueAccent : C.muted.withOpacity(0.3)),
                onPressed: isMine ? () => _showEditDialog(t) : null, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            const SizedBox(width: 4),
            IconButton(icon: Icon(Icons.delete, size: 18, color: isMine ? C.danger : C.muted.withOpacity(0.3)),
                onPressed: isMine ? () => _showDeleteDialog(t) : null, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          ]),
        );
      },
    );
  }

  void _printUlang(Map<String, dynamic> t) {
    final dt = tglJam.parse(t['time']);
    _printStruk(t['detail'] ?? '', t['amount'], t['method'], dt);
  }

  // ===== MENU PICKER (INPUT CEPAT) =====
  void _showMenuPicker(int amount) {
    _showMenuSheet(amount);
    _refreshMenuBackground();
  }

  void _showMenuSheet(int amount) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(builder: (ctx, setBs) {
        final currentMenus = boxMenus.values
            .whereType<Map>()
            .where((e) => e['pendingDelete'] != true)
            .map((e) => MenuItem(
              id: e['id'].toString(),
              nama: e['nama'].toString(),
              harga: (e['harga'] as num).toInt(),
              status: e['status'].toString(),
            ))
            .toList();

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(rupiah.format(amount),
                style: const TextStyle(color: C.neon, fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('Pilih Menu:', style: TextStyle(color: C.muted, fontSize: 12)),
            const SizedBox(height: 12),
            if (currentMenus.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Belum ada menu. Tambahkan di menu 👤 → Kelola Menu',
                    textAlign: TextAlign.center, style: TextStyle(color: C.muted)))
            else
              Wrap(
                spacing: 10, runSpacing: 10, alignment: WrapAlignment.center,
                children: currentMenus.where((m) => m.status == 'Aktif').map((m) => SizedBox(
                  width: 130,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.cardLight, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _addToCart(m, amount);
                    },
                    child: Text(m.nama, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                )).toList(),
              ),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          ]),
        );
      }),
    );
  }

  // ===== INPUT MANUAL =====
  void _showManualInput() {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Input Manual'),
      content: TextField(controller: ctrl, keyboardType: TextInputType.number, autofocus: true,
        decoration: const InputDecoration(hintText: 'Nominal', prefixText: 'Rp ')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () {
            final v = int.tryParse(ctrl.text) ?? 0;
            Navigator.pop(context);
            if (v > 0) _showMenuPickerManual(v);
          },
          child: const Text('LANJUT'),
        ),
      ],
    ));
  }

  // FIXED: SELALU BACA DARI HIVE
  void _showMenuPickerManual(int amount) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(builder: (ctx, setBs) {
        final currentMenus = boxMenus.values
            .whereType<Map>()
            .where((e) => e['pendingDelete'] != true)
            .map((e) => MenuItem(
              id: e['id'].toString(),
              nama: e['nama'].toString(),
              harga: (e['harga'] as num).toInt(),
              status: e['status'].toString(),
            ))
            .toList();

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(rupiah.format(amount),
                style: const TextStyle(color: C.neon, fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('Pilih Menu:', style: TextStyle(color: C.muted, fontSize: 12)),
            const SizedBox(height: 12),
            if (currentMenus.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() => cart.add(CartItem(
                        menuId: 'CUSTOM-${DateTime.now().millisecondsSinceEpoch}',
                        nama: 'Custom', harga: amount)));
                  },
                  child: Text('Tambahkan Custom ${rupiah.format(amount)}'),
                ),
              )
            else
              Wrap(
                spacing: 10, runSpacing: 10, alignment: WrapAlignment.center,
                children: currentMenus.where((m) => m.status == 'Aktif').map((m) => SizedBox(
                  width: 130,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: C.cardLight, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() => cart.add(CartItem(menuId: m.id, nama: m.nama, harga: amount)));
                    },
                    child: Text(m.nama, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                )).toList(),
              ),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          ]),
        );
      }),
    );
  }

  // ===== CART =====
  void _showCart() {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(builder: (ctx, setBs) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          const Text('🛒 KERANJANG', style: TextStyle(color: C.neon, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
            child: ListView.builder(
              shrinkWrap: true, itemCount: cart.length,
              itemBuilder: (_, i) {
                final c = cart[i];
                return ListTile(
                  title: Text('${c.nama} ${c.qty}x'),
                  subtitle: Text(rupiah.format(c.harga)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(rupiah.format(c.harga * c.qty), style: const TextStyle(fontWeight: FontWeight.bold)),
                    IconButton(icon: const Icon(Icons.close, size: 18, color: C.danger),
                      onPressed: () {
                        _removeFromCart(i);
                        Navigator.pop(ctx);
                        if (cart.isNotEmpty) _showCart();
                      }),
                  ]),
                );
              },
            ),
          ),
          const Divider(),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Text('TOTAL', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text(_cartTotal, style: const TextStyle(color: C.neon, fontWeight: FontWeight.bold, fontSize: 18)),
            ])),
          const SizedBox(height: 12),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(children: [
              Expanded(child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.withOpacity(0.2),
                  foregroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () { Navigator.pop(ctx); _saveTransaction('Tunai'); },
                icon: const Icon(Icons.money),
                label: const Text('TUNAI', style: TextStyle(fontWeight: FontWeight.bold)),
              )),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.withOpacity(0.2),
                  foregroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () { Navigator.pop(ctx); _saveTransaction('QRIS'); },
                icon: const Icon(Icons.qr_code),
                label: const Text('QRIS', style: TextStyle(fontWeight: FontWeight.bold)),
              )),
            ]),
          ),
        ]),
      )),
    );
  }

  // ===== EDIT DIALOG =====
  void _showEditDialog(Map<String, dynamic> trx) {
    final ctrl = TextEditingController(text: trx['amount'].toString());
    String metode = trx['method'];
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Edit Transaksi'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: ctrl, keyboardType: TextInputType.number,
          decoration: const InputDecoration(prefixText: 'Rp ', hintText: 'Nominal')),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: ChoiceChip(
            label: const Text('Tunai', style: TextStyle(fontSize: 12)),
            selected: metode == 'Tunai', selectedColor: Colors.green,
            labelStyle: TextStyle(color: metode == 'Tunai' ? Colors.black : Colors.white),
            onSelected: (_) => setSt(() => metode = 'Tunai'),
          )),
          const SizedBox(width: 8),
          Expanded(child: ChoiceChip(
            label: const Text('QRIS', style: TextStyle(fontSize: 12)),
            selected: metode == 'QRIS', selectedColor: Colors.blue,
            labelStyle: const TextStyle(color: Colors.white),
            onSelected: (_) => setSt(() => metode = 'QRIS'),
          )),
        ]),
        const SizedBox(height: 12),
        Text(trx['time'], style: const TextStyle(color: C.muted, fontSize: 11)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () {
            final v = int.tryParse(ctrl.text) ?? 0;
            if (v <= 0) return;
            Navigator.pop(ctx);
            _editTrx(trx['id'], v, metode);
          },
          child: const Text('SIMPAN'),
        ),
      ],
    )));
  }

  void _showDeleteDialog(Map<String, dynamic> trx) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Hapus Transaksi?'),
      content: Text('${rupiah.format(trx['amount'])} (${trx['method']})'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.danger, foregroundColor: Colors.white),
          onPressed: () { Navigator.pop(context); _deleteTrx(trx['id']); },
          child: const Text('HAPUS'),
        ),
      ],
    ));
  }

  // ===== MENU 👤 =====
  void _showMenu() {
    showModalBottomSheet(context: context, backgroundColor: C.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        ListTile(leading: const Icon(Icons.person, color: C.neon), title: const Text('Ganti Kasir'),
            onTap: () { Navigator.pop(context); _gantiKasir(); }),
        ListTile(leading: const Icon(Icons.menu_book, color: C.neon), title: const Text('Kelola Menu'),
            onTap: () { Navigator.pop(context); _kelolaMenu(); }),
        ListTile(leading: const Icon(Icons.cloud_download, color: C.neon), title: const Text('Restore Data 7 Hari'),
            onTap: () { Navigator.pop(context); _confirmRestore(); }),
        ListTile(leading: const Icon(Icons.store, color: C.neon), title: const Text('Pengaturan Toko'),
            onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const PengaturanTokoScreen())); }),
        ListTile(leading: const Icon(Icons.print, color: C.neon), title: const Text('Pengaturan Printer'),
            onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const PengaturanPrinterScreen())); }),
        const SizedBox(height: 12),
      ]));
  }

  void _confirmRestore() {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Restore Data?'),
      content: const Text('Tarik data 7 hari terakhir + menu dari Sheets ke HP ini?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () { Navigator.pop(context); _restore7Days(); },
          child: const Text('RESTORE'),
        ),
      ],
    ));
  }

  void _gantiKasir() {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Ganti Kasir?'),
      content: Text('Anda akan keluar dari sesi ${widget.kasir}.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () async {
            final p = await SharedPreferences.getInstance();
            await p.remove('kasir');
            await p.remove('cabang');
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const SetupScreen()), (r) => false);
          },
          child: const Text('GANTI'),
        ),
      ],
    ));
  }

  Future<void> _kelolaMenu() async {
    final pin = await _askPin();
    if (pin == null) return;
    final p = await SharedPreferences.getInstance();
    final expected = p.getString('pin_owner') ?? '1234';
    if (pin != expected) { _snack('PIN salah'); return; }
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => KelolaMenuScreen(onSaved: _loadMenus)));
  }

  Future<String?> _askPin() async {
    final ctrl = TextEditingController();
    return showDialog<String>(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('PIN Owner'),
      content: TextField(controller: ctrl, keyboardType: TextInputType.number,
        obscureText: true, autofocus: true,
        decoration: const InputDecoration(hintText: '4 digit')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () => Navigator.pop(context, ctrl.text),
          child: const Text('OK'),
        ),
      ],
    ));
  }
}

// ================== KELOLA MENU SCREEN ==================
class KelolaMenuScreen extends StatefulWidget {
  final VoidCallback onSaved;
  const KelolaMenuScreen({required this.onSaved, super.key});
  @override
  State<KelolaMenuScreen> createState() => _KelolaMenuScreenState();
}

class _KelolaMenuScreenState extends State<KelolaMenuScreen> {
  final boxMenus = Hive.box('menus_local');
  List<MenuItem> menus = [];
  int pendingSync = 0;
  final Set<String> syncingIds = {};

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _fetchServer();
  }

  void _loadLocal() {
    try {
      final all = boxMenus.values.whereType<Map>().toList();
      final list = <MenuItem>[];
      int pendingCount = 0;

      for (final e in all) {
        final isPendingDelete = e['pendingDelete'] == true;
        final isPending = e['pending'] == true;

        if (isPending && !isPendingDelete) pendingCount++;
        if (isPendingDelete) continue;

        try {
          list.add(MenuItem(
            id: e['id'].toString(),
            nama: (e['nama'] ?? '').toString(),
            harga: (e['harga'] as num).toInt(),
            status: (e['status'] ?? 'Aktif').toString(),
          ));
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          menus = list;
          pendingSync = pendingCount;
        });
      }
    } catch (_) {
      if (mounted) setState(() { menus = []; pendingSync = 0; });
    }
  }

  Future<void> _fetchServer() async {
    try {
      final res = await http.get(Uri.parse('$WEB_APP_URL?action=getMenu'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final list = List<Map<String, dynamic>>.from(data['data'] ?? []);
        for (final item in list) {
          final id = item['id'].toString();
          if (!boxMenus.containsKey(id)) {
            await boxMenus.put(id, {
              'id': id,
              'nama': item['nama'],
              'harga': item['harga'],
              'status': item['status'],
              'pending': false,
            });
          }
        }
        _loadLocal();
      }
    } catch (_) {}
  }

  Future<void> _save(MenuItem menu) async {
    final isNew = menu.id.isEmpty;
    final id = isNew ? 'M${DateTime.now().millisecondsSinceEpoch}' : menu.id;

    await boxMenus.put(id, {
      'id': id,
      'nama': menu.nama,
      'harga': menu.harga,
      'status': menu.status,
      'pending': true,
      'pendingDelete': false,
    });

    _loadLocal();
    widget.onSaved();
    _syncToServer(id);
  }

  Future<void> _delete(String id) async {
    final existing = boxMenus.get(id);
    if (existing != null) {
      final m = Map<String, dynamic>.from(existing);
      final isNewLocal = m['pending'] == true && m['id'].toString().startsWith('M17');
      if (isNewLocal) {
        await boxMenus.delete(id);
      } else {
        m['pending'] = true;
        m['pendingDelete'] = true;
        await boxMenus.put(id, m);
      }
    }
    _loadLocal();
    widget.onSaved();
    _syncToServer(id, isDelete: true);
  }

  Future<void> _syncToServer(String id, {bool isDelete = false}) async {
    try {
      if (isDelete) {
        final res = await _apiPost({'token': API_KEY, 'action': 'deleteMenu', 'id': id});
        if (res.statusCode == 200) {
          final r = jsonDecode(res.body);
          if (r['status'] == 'success') {
            await boxMenus.delete(id);
            _loadLocal();
          }
        }
      } else {
        final item = boxMenus.get(id);
        if (item == null) return;
        final m = Map<String, dynamic>.from(item);
        final res = await _apiPost({
          'token': API_KEY, 'action': 'saveMenu',
          'menu': {'id': id, 'nama': m['nama'], 'harga': m['harga'], 'status': m['status']},
        });
        if (res.statusCode == 200) {
          final r = jsonDecode(res.body);
          if (r['status'] == 'success') {
            m['pending'] = false;
            m['pendingDelete'] = false;
            await boxMenus.put(id, m);
            _loadLocal();
          }
        }
      }
    } catch (_) {}
  }

  // RETRY SYNC PER ITEM
  Future<void> _retrySyncMenu(String id) async {
    if (syncingIds.contains(id)) return;
    setState(() => syncingIds.add(id));

    final item = boxMenus.get(id);
    if (item == null) {
      setState(() => syncingIds.remove(id));
      return;
    }
    final m = Map<String, dynamic>.from(item);

    try {
      if (m['pendingDelete'] == true) {
        final res = await _apiPost({'token': API_KEY, 'action': 'deleteMenu', 'id': id});
        if (res.statusCode == 200) {
          final r = jsonDecode(res.body);
          if (r['status'] == 'success') {
            await boxMenus.delete(id);
            _snack('✅ Menu dihapus dari Sheets');
          } else {
            _snack('❌ Gagal: ${r['message']}');
          }
        } else {
          _snack('❌ Gagal kirim (HTTP ${res.statusCode})');
        }
      } else {
        final res = await _apiPost({
          'token': API_KEY, 'action': 'saveMenu',
          'menu': {'id': id, 'nama': m['nama'], 'harga': m['harga'], 'status': m['status']},
        });
        if (res.statusCode == 200) {
          final r = jsonDecode(res.body);
          if (r['status'] == 'success') {
            m['pending'] = false;
            m['pendingDelete'] = false;
            await boxMenus.put(id, m);
            _snack('✅ Menu tersinkron');
          } else {
            _snack('❌ Gagal: ${r['message']}');
          }
        } else {
          _snack('❌ Gagal kirim (HTTP ${res.statusCode})');
        }
      }
    } catch (e) {
      _snack('❌ Tidak ada koneksi. Coba lagi.');
    }

    _loadLocal();
    if (mounted) setState(() => syncingIds.remove(id));
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _showEdit(MenuItem? menu) {
    final ctrlNama = TextEditingController(text: menu?.nama ?? '');
    final ctrlHarga = TextEditingController(text: menu?.harga.toString() ?? '');
    String status = menu?.status ?? 'Aktif';
    showDialog(context: context, builder: (_) => StatefulBuilder(builder: (ctx, setSt) => AlertDialog(
      backgroundColor: C.card,
      title: Text(menu == null ? 'Tambah Menu' : 'Edit Menu'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctrlNama, textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nama Menu')),
        const SizedBox(height: 12),
        TextField(controller: ctrlHarga, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Harga (referensi)', prefixText: 'Rp ')),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: ChoiceChip(
            label: const Text('Aktif', style: TextStyle(fontSize: 12)),
            selected: status == 'Aktif', selectedColor: Colors.green,
            onSelected: (_) => setSt(() => status = 'Aktif'),
          )),
          const SizedBox(width: 8),
          Expanded(child: ChoiceChip(
            label: const Text('Nonaktif', style: TextStyle(fontSize: 12)),
            selected: status == 'Nonaktif', selectedColor: C.warning,
            onSelected: (_) => setSt(() => status = 'Nonaktif'),
          )),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.neon, foregroundColor: Colors.black),
          onPressed: () {
            final nama = ctrlNama.text.trim();
            final harga = int.tryParse(ctrlHarga.text) ?? 0;
            if (nama.isEmpty) { _snack('Isi nama menu dulu'); return; }
            Navigator.pop(ctx);
            _save(MenuItem(id: menu?.id ?? '', nama: nama, harga: harga, status: status));
          },
          child: const Text('SIMPAN'),
        ),
      ],
    )));
  }

  void _confirmDelete(MenuItem m) {
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: C.card,
      title: const Text('Hapus Menu?'),
      content: Text(m.nama),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: C.danger, foregroundColor: Colors.white),
          onPressed: () { Navigator.pop(context); _delete(m.id); },
          child: const Text('HAPUS'),
        ),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kelola Menu'),
        backgroundColor: C.card, foregroundColor: C.neon,
        actions: [
          if (pendingSync > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.sync, size: 14, color: C.warning),
                  const SizedBox(width: 4),
                  Text('$pendingSync pending', style: const TextStyle(color: C.warning, fontSize: 11)),
                ]),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.neon, foregroundColor: Colors.black,
        onPressed: () => _showEdit(null),
        icon: const Icon(Icons.add),
        label: const Text('Tambah', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: menus.isEmpty
          ? const Center(child: Text('Belum ada menu', style: TextStyle(color: C.muted)))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: menus.length,
              itemBuilder: (_, i) {
                final m = menus[i];
                final isAktif = m.status == 'Aktif';
                final raw = boxMenus.get(m.id);
                final isPending = raw != null && raw['pending'] == true;
                return Card(color: C.card, margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Row(children: [
                      Expanded(child: Text(m.nama, style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isAktif ? Colors.white : C.muted))),
                      if (isPending)
                        syncingIds.contains(m.id)
                            ? const Padding(
                                padding: EdgeInsets.only(left: 6),
                                child: SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(
                                    color: C.warning, strokeWidth: 2),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.sync, size: 16, color: C.warning),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                tooltip: 'Tap untuk sinkron',
                                onPressed: () => _retrySyncMenu(m.id),
                              ),
                    ]),
                    subtitle: Text(isAktif ? 'Aktif' : 'Nonaktif',
                        style: TextStyle(color: isAktif ? Colors.green : C.warning, fontSize: 11)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.edit, size: 18, color: Colors.lightBlueAccent),
                          onPressed: () => _showEdit(m)),
                      IconButton(icon: const Icon(Icons.delete, size: 18, color: C.danger),
                          onPressed: () => _confirmDelete(m)),
                    ]),
                  ));
              },
            ),
    );
  }
}

// ================== PENGATURAN TOKO SCREEN ==================
class PengaturanTokoScreen extends StatefulWidget {
  const PengaturanTokoScreen({super.key});
  @override
  State<PengaturanTokoScreen> createState() => _PengaturanTokoScreenState();
}

class _PengaturanTokoScreenState extends State<PengaturanTokoScreen> {
  final ctrlNamaToko = TextEditingController();
  final ctrlAlamat = TextEditingController();
  final ctrlTelp = TextEditingController();
  final ctrlFooter = TextEditingController();
  final ctrlPromo = TextEditingController();

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      ctrlNamaToko.text = p.getString('toko_nama') ?? 'CIRENG WOII';
      ctrlAlamat.text = p.getString('toko_alamat') ?? '';
      ctrlTelp.text = p.getString('toko_telp') ?? '';
      ctrlFooter.text = p.getString('toko_footer') ?? 'Terima kasih :)';
      ctrlPromo.text = p.getString('toko_promo') ?? '';
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('toko_nama', ctrlNamaToko.text.trim());
    await p.setString('toko_alamat', ctrlAlamat.text.trim());
    await p.setString('toko_telp', ctrlTelp.text.trim());
    await p.setString('toko_footer', ctrlFooter.text.trim());
    await p.setString('toko_promo', ctrlPromo.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tersimpan')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan Toko'), backgroundColor: C.card, foregroundColor: C.neon),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          _field('Nama Toko (di struk)', ctrlNamaToko),
          _field('Alamat', ctrlAlamat),
          _field('No. Telepon', ctrlTelp, keyboard: TextInputType.phone),
          _field('Footer Ucapan', ctrlFooter),
          _field('Promo / Catatan (Opsional)', ctrlPromo),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: C.neon, foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _save,
              child: const Text('SIMPAN', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl, {TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
        const SizedBox(height: 4),
        TextField(controller: ctrl, keyboardType: keyboard,
          decoration: InputDecoration(
            filled: true, fillColor: C.card,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          )),
      ]),
    );
  }
}

// ================== PENGATURAN PRINTER SCREEN ==================
class PengaturanPrinterScreen extends StatefulWidget {
  const PengaturanPrinterScreen({super.key});
  @override
  State<PengaturanPrinterScreen> createState() => _PengaturanPrinterScreenState();
}

class _PengaturanPrinterScreenState extends State<PengaturanPrinterScreen> {
  final BlueThermalPrinter printer = BlueThermalPrinter.instance;
  List<BluetoothDevice> devices = [];
  BluetoothDevice? selected;
  String? savedMac;
  bool scanning = false;
  bool connected = false;

  @override
  void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    await _requestPermissions();
    final p = await SharedPreferences.getInstance();
    savedMac = p.getString('printer_mac');
    await _loadDevices();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ].request();
  }

  Future<void> _loadDevices() async {
    setState(() => scanning = true);
    try {
      final list = await printer.getBondedDevices();
      setState(() {
        devices = list;
        if (savedMac != null) {
          try { selected = list.firstWhere((d) => d.address == savedMac); } catch (_) {}
        }
      });
    } catch (e) { _snack('Gagal scan: $e'); }
    setState(() => scanning = false);
  }

  Future<void> _connect() async {
    if (selected == null) { _snack('Pilih printer dulu'); return; }
    try {
      final isConn = await printer.isConnected ?? false;
      if (isConn) await printer.disconnect();
      await printer.connect(selected!);
      final p = await SharedPreferences.getInstance();
      await p.setString('printer_mac', selected!.address ?? '');
      setState(() => connected = true);
      _snack('Terhubung ke ${selected!.name}');
    } catch (e) {
      _snack('Gagal connect: $e');
      setState(() => connected = false);
    }
  }

  Future<void> _testPrint() async {
    try {
      await printer.printNewLine();
      await printer.printCustom('TEST PRINT', 2, 1);
      await printer.printCustom('Cireng Woi POS', 1, 1);
      await printer.printCustom('--------------------------------', 1, 1);
      await printer.printCustom('Printer OK!', 1, 1);
      await printer.printNewLine();
      await printer.printNewLine();
      await printer.paperCut();
      _snack('Test print dikirim');
    } catch (e) { _snack('Gagal test: $e'); }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan Printer'),
        backgroundColor: C.card, foregroundColor: C.neon,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _loadDevices)]),
      body: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Printer yang sudah di-pair di HP:', style: TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(height: 8),
          if (scanning) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: C.neon))),
          if (!scanning && devices.isEmpty)
            const Padding(padding: EdgeInsets.all(16),
              child: Text('Tidak ada printer. Pair dulu di Setting Bluetooth HP.',
                textAlign: TextAlign.center, style: TextStyle(color: C.muted))),
          if (!scanning && devices.isNotEmpty)
            Expanded(child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (_, i) {
                final d = devices[i];
                final isSelected = selected?.address == d.address;
                return Card(color: isSelected ? C.neon.withOpacity(0.15) : C.card,
                  child: ListTile(
                    leading: Icon(Icons.print, color: isSelected ? C.neon : C.muted),
                    title: Text(d.name ?? 'Unknown'),
                    subtitle: Text(d.address ?? '', style: const TextStyle(fontSize: 11)),
                    trailing: isSelected ? const Icon(Icons.check, color: C.neon) : null,
                    onTap: () => setState(() => selected = d),
                  ));
              },
            )),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: connected ? Colors.green : C.neon,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _connect,
            icon: Icon(connected ? Icons.check_circle : Icons.bluetooth),
            label: Text(connected ? 'TERHUBUNG' : 'HUBUNGKAN',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: C.neon, side: const BorderSide(color: C.neon),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: connected ? _testPrint : null,
            icon: const Icon(Icons.print),
            label: const Text('TEST PRINT', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ])),
    );
  }
}
