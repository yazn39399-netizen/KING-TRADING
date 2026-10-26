import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const pairs = {
  'XAUUSD': 'GC=F', 'BITCOIN': 'BTC-USD', 'EURUSD': 'EURUSD=X',
  'USDJPY': 'USDJPY=X', 'CADJPY': 'CADJPY=X', 'AUDCAD': 'AUDCAD=X',
};
const strategies = [
  'SMC + ICT Hybrid Strategy', 'Price Action', 'Elliott Wave Theory',
  'Volume Profile & Footprint', 'Fundamental & Sentiment Analysis',
];
const labels = {
  'open': '⏳ مفتوحة', 'tp1': '✅ الهدف 1 (مستمرة)', 'tp1x': '✅ الهدف 1 (أُغلقت)',
  'tp2': '🎯 الهدف 2', 'sl': '❌ وقف الخسارة',
};

class C {
  double t, o, h, l, c, v;
  C(this.t, this.o, this.h, this.l, this.c, this.v);
}

Future<List<C>> fetchCandles(String sym, bool scalp) async {
  final u = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/${pairs[sym]}'
      '?interval=${scalp ? '5m' : '1h'}&range=${scalp ? '5d' : '1mo'}');
  final r = await http.get(u, headers: {'User-Agent': 'Mozilla/5.0'});
  final j = jsonDecode(r.body)['chart']['result'][0];
  final ts = j['timestamp'] as List;
  final q = j['indicators']['quote'][0];
  final out = <C>[];
  for (var i = 0; i < ts.length; i++) {
    if (q['close'][i] == null || q['high'][i] == null || q['low'][i] == null || q['open'][i] == null) continue;
    out.add(C((ts[i] as num).toDouble(), q['open'][i].toDouble(), q['high'][i].toDouble(),
        q['low'][i].toDouble(), q['close'][i].toDouble(), (q['volume'][i] ?? 0).toDouble()));
  }
  return out;
}

double ema(List<double> x, int n) {
  final k = 2 / (n + 1);
  var e = x.first;
  for (final v in x) { e = v * k + e * (1 - k); }
  return e;
}

double atr(List<C> c, [int n = 14]) {
  var s = 0.0;
  for (var i = c.length - n; i < c.length; i++) {
    s += max(c[i].h - c[i].l, max((c[i].h - c[i - 1].c).abs(), (c[i].l - c[i - 1].c).abs()));
  }
  return s / n;
}

double rsi(List<C> c, [int n = 14]) {
  var g = 0.0, l = 0.0;
  for (var i = c.length - n; i < c.length; i++) {
    final d = c[i].c - c[i - 1].c;
    if (d > 0) { g += d; } else { l -= d; }
  }
  return l == 0 ? 100 : 100 - 100 / (1 + g / l);
}

class Trade {
  String sym, mode, strat, status;
  bool buy;
  double entry, sl, tp1, tp2;
  int time;
  String why;
  Trade(this.sym, this.mode, this.strat, this.buy, this.entry, this.sl, this.tp1, this.tp2,
      this.time, this.why, [this.status = 'open']);
  Map<String, dynamic> toJson() => {
        'sym': sym, 'mode': mode, 'strat': strat, 'buy': buy, 'entry': entry, 'sl': sl,
        'tp1': tp1, 'tp2': tp2, 'time': time, 'why': why, 'status': status,
      };
  factory Trade.fromJson(Map<String, dynamic> j) => Trade(j['sym'], j['mode'], j['strat'], j['buy'],
      j['entry'], j['sl'], j['tp1'], j['tp2'], j['time'], j['why'], j['status']);
}

String fmt(double v, String sym) =>
    v.toStringAsFixed(sym == 'XAUUSD' || sym == 'BITCOIN' ? 2 : (sym.contains('JPY') ? 3 : 5));

Trade? analyze(List<C> c, String sym, bool scalp, String st) {
  if (c.length < 80) return null;
  final cl = c.map((e) => e.c).toList();
  final px = cl.last, a = atr(c);
  final up = ema(cl, 20) > ema(cl, 50);
  final last = c.last, prev = c[c.length - 2];
  final w = c.sublist(c.length - 30, c.length - 3);
  final lo = w.map((e) => e.l).reduce(min), hi = w.map((e) => e.h).reduce(max);
  final rec = c.sublist(c.length - 3);
  final trendWhy = up ? 'لا إشارة خاصة، متابعة الاتجاه الصاعد (EMA20>EMA50)' : 'لا إشارة خاصة، متابعة الاتجاه الهابط (EMA20<EMA50)';
  bool buy = up;
  String why = trendWhy;
  final i = strategies.indexOf(st);
  if (i == 0) {
    if (rec.any((e) => e.l < lo) && last.c > lo) { buy = true; why = 'سحب سيولة تحت القاع ثم إغلاق فوقه (Liquidity Sweep)'; }
    else if (rec.any((e) => e.h > hi) && last.c < hi) { buy = false; why = 'سحب سيولة فوق القمة ثم إغلاق تحتها (Liquidity Sweep)'; }
  } else if (i == 1) {
    final body = (last.c - last.o).abs() + 1e-9;
    final lw = min(last.o, last.c) - last.l, uw = last.h - max(last.o, last.c);
    if (prev.c < prev.o && last.c > last.o && last.c > prev.o && last.o < prev.c) { buy = true; why = 'شمعة ابتلاعية صاعدة'; }
    else if (prev.c > prev.o && last.c < last.o && last.c < prev.o && last.o > prev.c) { buy = false; why = 'شمعة ابتلاعية هابطة'; }
    else if (lw > 2 * body) { buy = true; why = 'شمعة رفض سعري (Pin Bar) من الأسفل'; }
    else if (uw > 2 * body) { buy = false; why = 'شمعة رفض سعري (Pin Bar) من الأعلى'; }
  } else if (i == 2) {
    final s = c.sublist(c.length - 60);
    final h2 = s.map((e) => e.h).reduce(max), l2 = s.map((e) => e.l).reduce(min);
    final retr = up ? (h2 - px) / (h2 - l2) : (px - l2) / (h2 - l2);
    if (retr >= 0.382 && retr <= 0.786) {
      why = 'تصحيح فيبو ${(retr * 100).toStringAsFixed(0)}% داخل موجة، متوقع موجة دافعة بنفس الاتجاه';
    } else { why = 'السعر خارج منطقة التصحيح (38-78%)، ثقة أقل. $trendWhy'; }
  } else if (i == 3) {
    final s = c.sublist(c.length - 100);
    final mn = s.map((e) => e.l).reduce(min), mx = s.map((e) => e.h).reduce(max);
    const bins = 24;
    final vol = List.filled(bins, 0.0);
    final noVol = s.every((e) => e.v == 0);
    for (final e in s) {
      final b = (((e.c - mn) / (mx - mn)) * (bins - 1)).round().clamp(0, bins - 1);
      vol[b] += noVol ? 1 : e.v;
    }
    final poc = mn + (vol.indexOf(vol.reduce(max)) + 0.5) * (mx - mn) / bins;
    buy = px > poc;
    why = 'السعر ${buy ? 'فوق' : 'تحت'} نقطة التحكم POC (${fmt(poc, sym)})${noVol ? ' (تقدير بدون حجم حقيقي)' : ''}';
  } else {
    final r = rsi(c);
    if (r > 55) { buy = true; why = 'زخم/معنويات صاعدة (RSI ${r.toStringAsFixed(0)})'; }
    else if (r < 45) { buy = false; why = 'زخم/معنويات هابطة (RSI ${r.toStringAsFixed(0)})'; }
  }
  final risk = a * (scalp ? 1.0 : 1.5);
  final d = buy ? 1 : -1;
  return Trade(sym, scalp ? 'سكالب' : 'سوينغ', st, buy, px, px - d * risk, px + d * risk * 1.5,
      px + d * risk * 3, DateTime.now().millisecondsSinceEpoch, why);
}

String resolve(Trade t, List<C> cs) {
  var s = t.status;
  final d = t.buy ? 1 : -1;
  for (final x in cs) {
    if (s == 'sl' || s == 'tp2' || s == 'tp1x') break;
    if (x.t * 1000 <= t.time) continue;
    final low = t.buy ? x.l : x.h, high = t.buy ? x.h : x.l;
    final stop = s == 'tp1' ? t.entry : t.sl;
    if (d * (low - stop) <= 0) { s = s == 'tp1' ? 'tp1x' : 'sl'; break; }
    if (d * (high - t.tp2) >= 0) { s = 'tp2'; break; }
    if (d * (high - t.tp1) >= 0) s = 'tp1';
  }
  return s;
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber, brightness: Brightness.dark)),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  String sym = pairs.keys.first, strat = strategies.first;
  bool scalp = true, busy = false;
  Trade? sig;
  String? err;
  List<Trade> log = [];

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    setState(() => log = (p.getStringList('trades') ?? []).map((e) => Trade.fromJson(jsonDecode(e))).toList());
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('trades', log.map((e) => jsonEncode(e.toJson())).toList());
  }

  Future<void> run() async {
    setState(() { busy = true; err = null; sig = null; });
    try {
      final c = await fetchCandles(sym, scalp);
      final s = analyze(c, sym, scalp, strat);
      setState(() { sig = s; if (s == null) err = 'البيانات غير كافية'; });
    } catch (e) { setState(() => err = 'تعذر جلب الأسعار، تأكد من الإنترنت'); }
    setState(() => busy = false);
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      for (final m in [true, false]) {
        final open = log.where((t) => (t.mode == 'سكالب') == m && (t.status == 'open' || t.status == 'tp1'));
        for (final s in open.map((t) => t.sym).toSet()) {
          final c = await fetchCandles(s, m);
          for (final t in open.where((t) => t.sym == s)) { t.status = resolve(t, c); }
        }
      }
      await save();
    } catch (_) {}
    setState(() => busy = false);
  }

  Widget chips<T>(List<T> items, T sel, String Function(T) name, void Function(T) on) => Wrap(
        spacing: 6,
        children: [for (final i in items) ChoiceChip(label: Text(name(i)), selected: i == sel, onSelected: (_) => on(i))],
      );

  Widget row(String k, String v, [Color? col]) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k), Text(v, style: TextStyle(fontWeight: FontWeight.bold, color: col))]),
      );

  Widget analyzeTab() => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('الزوج'), chips(pairs.keys.toList(), sym, (e) => e, (e) => setState(() => sym = e)),
        const SizedBox(height: 12), const Text('نوع الصفقة'),
        chips([true, false], scalp, (e) => e ? 'سكالب' : 'سوينغ', (e) => setState(() => scalp = e)),
        const SizedBox(height: 12), const Text('استراتيجية التحليل'),
        chips(strategies, strat, (e) => e, (e) => setState(() => strat = e)),
        const SizedBox(height: 16),
        FilledButton(onPressed: busy ? null : run, child: Text(busy ? 'جاري التحليل...' : 'حلّل وأعطني صفقة')),
        if (err != null) Padding(padding: const EdgeInsets.all(12), child: Text(err!, style: const TextStyle(color: Colors.redAccent))),
        if (sig != null) tradeCard(sig!, true),
        const Padding(padding: EdgeInsets.all(12), child: Text('⚠️ تحليل آلي تعليمي وليس نصيحة مالية. لا توجد صفقة مضمونة.', style: TextStyle(fontSize: 12, color: Colors.grey))),
      ]);

  Widget tradeCard(Trade t, bool canSave) {
    final col = t.buy ? Colors.greenAccent : Colors.redAccent;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${t.sym}  •  ${t.buy ? 'شراء BUY' : 'بيع SELL'}  •  ${t.mode}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: col)),
          Text(t.strat, style: const TextStyle(color: Colors.grey)),
          const Divider(),
          row('الدخول', fmt(t.entry, t.sym)),
          row('وقف الخسارة', fmt(t.sl, t.sym), Colors.redAccent),
          row('الهدف 1 (1.5R)', fmt(t.tp1, t.sym), Colors.greenAccent),
          row('الهدف 2 (3R)', fmt(t.tp2, t.sym), Colors.greenAccent),
          const SizedBox(height: 6),
          Text('السبب: ${t.why}', style: const TextStyle(fontSize: 13)),
          if (canSave)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: OutlinedButton(
                onPressed: () async {
                  log.insert(0, t);
                  await save();
                  setState(() => sig = null);
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الصفقة في السجل')));
                },
                child: const Text('سجّل الصفقة'),
              ),
            )
          else
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(labels[t.status]!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        ]),
      ),
    );
  }

  Widget logTab() {
    final wins = log.where((t) => ['tp1', 'tp1x', 'tp2'].contains(t.status)).length;
    final losses = log.where((t) => t.status == 'sl').length;
    final rate = wins + losses == 0 ? 0 : wins * 100 / (wins + losses);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('✅ $wins   ❌ $losses   نسبة النجاح ${rate.toStringAsFixed(0)}%'),
        IconButton(onPressed: busy ? null : refresh, icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh)),
      ]),
      if (log.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا توجد صفقات مسجلة'))),
      for (final t in log)
        Dismissible(
          key: ValueKey(t.time),
          onDismissed: (_) { log.remove(t); save(); setState(() {}); },
          child: tradeCard(t, false),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('إشارات التداول')),
        body: tab == 0 ? analyzeTab() : logTab(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) { setState(() => tab = i); if (i == 1) refresh(); },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.analytics), label: 'تحليل'),
            NavigationDestination(icon: Icon(Icons.history), label: 'السجل'),
          ],
        ),
      );
}
