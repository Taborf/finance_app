import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const PatrimonioApp());

class PatrimonioApp extends StatelessWidget {
  const PatrimonioApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, primary: const Color(0xFF0D47A1)),
      scaffoldBackgroundColor: Colors.white,
    ),
    home: const MainNavigation(),
  );
}

// --- MODELLO DATI ---
enum TransactionType { buy, sell, deposit, withdrawal, exchange, dividend }

class Transaction {
  final DateTime date;
  final TransactionType type;
  final String asset;
  final double qty;
  final double price;
  final double fees;
  final String currency;

  Transaction({
    required this.date, required this.type, required this.asset,
    required this.qty, required this.price, this.fees = 0, required this.currency,
  });

  Map<String, dynamic> toJson() => {
    'date': date.toIso8601String(),
    'type': type.index,
    'asset': asset,
    'qty': qty,
    'price': price,
    'fees': fees,
    'currency': currency,
  };

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
    date: DateTime.parse(json['date']),
    type: TransactionType.values[json['type']],
    asset: json['asset'],
    qty: (json['qty'] as num).toDouble(),
    price: (json['price'] as num).toDouble(),
    fees: (json['fees'] as num).toDouble(),
    currency: json['currency'],
  );
}

// --- NAVIGAZIONE E LOGICA CORE ---
class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});
  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _selectedIndex = 0;
  double marketRate = 1.09;
  String lastUpdate = "Mai aggiornato";
  List<Transaction> history = [];
  Map<String, double> livePrices = {}; // Mappa per i prezzi in tempo reale
  Timer? _refreshTimer;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _loadData().then((_) => _startPriceTimer());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startPriceTimer() {
    _refreshPrices(); 
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (timer) {
      _refreshPrices();
    });
  }

  Future<void> _refreshPrices() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);

    // Intestazioni per "ingannare" Yahoo e fargli credere che siamo un browser normale
    final Map<String, String> headers = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Origin': 'https://finance.yahoo.com',
    };

    try {
      // 1. Cambio EUR/USD
      final fxRes = await http.get(
        Uri.parse('https://query1.finance.yahoo.com/v7/finance/quote?symbols=EURUSD=X'),
        headers: headers,
      ).timeout(const Duration(seconds: 10));
      
      if (fxRes.statusCode == 200) {
        final data = jsonDecode(fxRes.body);
        if (data['quoteResponse']['result'].isNotEmpty) {
          marketRate = (data['quoteResponse']['result'][0]['regularMarketPrice'] as num).toDouble();
        }
      }

      // 2. Titoli
      final List<String> tickersList = portfolio.map((a) => a['ticker'].toString()).toList();
      if (tickersList.isNotEmpty) {
        final symbols = tickersList.join(',');
        final stockRes = await http.get(
          Uri.parse('https://query1.finance.yahoo.com/v7/finance/quote?symbols=$symbols'),
          headers: headers,
        ).timeout(const Duration(seconds: 10));
        
        if (stockRes.statusCode == 200) {
          final data = jsonDecode(stockRes.body);
          final List results = data['quoteResponse']['result'] ?? [];
          for (var res in results) {
            if (res['regularMarketPrice'] != null) {
              livePrices[res['symbol']] = (res['regularMarketPrice'] as num).toDouble();
            }
          }
        }
      }
    } catch (e) {
      print("Errore: $e");
    } finally {
      setState(() {
        lastUpdate = DateFormat('dd/MM HH:mm').format(DateTime.now());
        _isRefreshing = false;
      });
      _saveData();
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      marketRate = prefs.getDouble('marketRate') ?? 1.09;
      lastUpdate = prefs.getString('lastUpdate') ?? lastUpdate;
      final String? stored = prefs.getString('history');
      if (stored != null) {
        final List decoded = jsonDecode(stored);
        history = decoded.map((item) => Transaction.fromJson(item)).toList();
      }
    });
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('marketRate', marketRate);
    await prefs.setString('lastUpdate', lastUpdate);
    await prefs.setString('history', jsonEncode(history.map((t) => t.toJson()).toList()));
  }

  // --- LOGICHE DI CALCOLO ---
  double get cashEur {
    double total = 0;
    for (var t in history) {
      if (t.currency == 'EUR') {
        if (t.type == TransactionType.deposit || t.type == TransactionType.dividend) total += t.qty;
        if (t.type == TransactionType.withdrawal) total -= t.qty;
        if (t.type == TransactionType.buy) total -= (t.qty * t.price + t.fees);
        if (t.type == TransactionType.sell) total += (t.qty * t.price - t.fees);
        if (t.type == TransactionType.exchange) total += (t.asset == "FROM_USD") ? t.qty : -t.qty;
      }
    }
    return total;
  }

  double get cashUsd {
    double total = 0;
    for (var t in history) {
      if (t.currency == 'USD') {
        if (t.type == TransactionType.dividend) total += t.qty;
        if (t.type == TransactionType.buy) total -= (t.qty * t.price + t.fees);
        if (t.type == TransactionType.sell) total += (t.qty * t.price - t.fees);
        if (t.type == TransactionType.exchange) total += (t.asset == "FROM_EUR") ? t.qty : -t.qty;
      }
    }
    return total;
  }

  double get capitaleInvestito {
    double d = history.where((t) => t.type == TransactionType.deposit).fold(0.0, (s, t) => s + t.qty);
    double w = history.where((t) => t.type == TransactionType.withdrawal).fold(0.0, (s, t) => s + t.qty);
    return d - w;
  }

  List<Map<String, dynamic>> get portfolio {
    Map<String, Map<String, dynamic>> assets = {};
    for (var t in history.where((t) => t.type == TransactionType.buy || t.type == TransactionType.sell)) {
      if (!assets.containsKey(t.asset)) {
        assets[t.asset] = {'ticker': t.asset, 'qty': 0.0, 'pmc': 0.0, 'cur': t.currency, 'lastPrice': t.price};
      }
      var a = assets[t.asset]!;
      if (t.type == TransactionType.buy) {
        double oldQty = a['qty'];
        double oldPmc = a['pmc'];
        a['qty'] += t.qty;
        a['pmc'] = ((oldQty * oldPmc) + (t.qty * t.price) + t.fees) / a['qty'];
      } else {
        a['qty'] -= t.qty;
      }
      // Se abbiamo un prezzo live, usalo, altrimenti resta l'ultimo prezzo di acquisto/vendita
      if (livePrices.containsKey(t.asset)) {
        a['lastPrice'] = livePrices[t.asset];
      }
    }
    return assets.values.where((a) => a['qty'] > 0.001).toList();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      HomeDashboard(cashEur: cashEur, cashUsd: cashUsd, capInv: capitaleInvestito, fx: marketRate, updateStr: lastUpdate, assets: portfolio),
      PortafoglioV6(assets: portfolio, fx: marketRate, isRefreshing: _isRefreshing, onRefresh: _refreshPrices),
      CassaPage(cashEur: cashEur, cashUsd: cashUsd, onAction: (t) { setState(() => history.add(t)); _saveData(); }, onFxUpdate: (v) { setState(() => marketRate = v); _saveData(); }),
      TradePage(onTrade: (t) { setState(() => history.add(t)); _saveData(); }),
      StoricoPage(history: history, onDelete: (i) { setState(() => history.removeAt(i)); _saveData(); }),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_selectedIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF0D47A1),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.pie_chart), label: 'Titoli'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet), label: 'Cassa'),
          BottomNavigationBarItem(icon: Icon(Icons.add_chart), label: 'Trade'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'Storico'),
        ],
      ),
    );
  }
}

// --- 1. HOME DASHBOARD ---
class HomeDashboard extends StatelessWidget {
  final double cashEur, cashUsd, capInv, fx;
  final String updateStr;
  final List<Map<String, dynamic>> assets;

  const HomeDashboard({super.key, required this.cashEur, required this.cashUsd, required this.capInv, required this.fx, required this.updateStr, required this.assets});

  @override
  Widget build(BuildContext context) {
    double titEur = assets.where((a) => a['cur'] == 'EUR').fold(0, (s, a) => s + (a['qty'] * a['lastPrice']));
    double titUsd = assets.where((a) => a['cur'] == 'USD').fold(0, (s, a) => s + (a['qty'] * a['lastPrice']));
    double totPatrimonio = cashEur + (cashUsd / fx) + titEur + (titUsd / fx);
    double guadagnoNetto = totPatrimonio - capInv;
    double mwr = capInv != 0 ? (guadagnoNetto / capInv) * 100 : 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: const Color(0xFF0D47A1), borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            _kpiRow("Totale Patrimonio", "${totPatrimonio.toStringAsFixed(2)} €", Colors.white, large: true),
            const Divider(color: Colors.white24, height: 20),
            _kpiRow("Capitale Investito", "${capInv.toStringAsFixed(2)} €", Colors.white70),
            _kpiRow("Guadagno Netto", "${guadagnoNetto.toStringAsFixed(2)} €", guadagnoNetto >= 0 ? Colors.greenAccent : Colors.redAccent),
            _kpiRow("MWR%", "${mwr.toStringAsFixed(2)}%", mwr >= 0 ? Colors.greenAccent : Colors.redAccent),
          ]),
        ),
        const SizedBox(height: 15),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text("FX EUR/USD: ${fx.toStringAsFixed(4)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Text("Update: $updateStr", style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
        const Divider(height: 30),
        _sectionHeader("3. SEZIONE LIQUIDITÀ (CASH)"),
        _rowItem("Conto EUR", "${cashEur.toStringAsFixed(2)} €", "${cashEur.toStringAsFixed(2)} €"),
        _rowItem("Conto USD", "\$ ${cashUsd.toStringAsFixed(2)}", "${(cashUsd / fx).toStringAsFixed(2)} €"),
        _sectionTotal("Totale Cassa", "${(cashEur + (cashUsd / fx)).toStringAsFixed(2)} €"),
        const SizedBox(height: 25),
        _sectionHeader("4. SEZIONE INVESTIMENTI (TITOLI)"),
        _rowItem("Titoli EUR", "${titEur.toStringAsFixed(2)} €", "${titEur.toStringAsFixed(2)} €"),
        _rowItem("Titoli USD", "\$ ${titUsd.toStringAsFixed(2)}", "${(titUsd / fx).toStringAsFixed(2)} €"),
        _sectionTotal("Totale Titoli", "${(titEur + (titUsd / fx)).toStringAsFixed(2)} €"),
      ],
    );
  }

  Widget _kpiRow(String l, String v, Color c, {bool large = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(l, style: TextStyle(color: Colors.white, fontSize: large ? 16 : 13)),
      Text(v, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: large ? 22 : 15)),
    ]),
  );

  Widget _sectionHeader(String t) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF0D47A1))));
  
  Widget _rowItem(String l, String o, String e) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      Expanded(child: Text(l, style: const TextStyle(fontWeight: FontWeight.w500))),
      Text(o, style: const TextStyle(color: Colors.black54, fontSize: 13)),
      SizedBox(width: 110, child: Text(e, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
    ]),
  );

  Widget _sectionTotal(String l, String v) => Container(
    margin: const EdgeInsets.only(top: 5), padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(color: Colors.blueGrey.shade50, borderRadius: BorderRadius.circular(4)),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(l, style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(v, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0D47A1))),
    ]),
  );
}

// --- 2. PAGINA TITOLI V6 ---
class PortafoglioV6 extends StatefulWidget {
  final List<Map<String, dynamic>> assets;
  final double fx;
  final bool isRefreshing;
  final Future<void> Function() onRefresh;
  const PortafoglioV6({super.key, required this.assets, required this.fx, required this.isRefreshing, required this.onRefresh});
  @override State<PortafoglioV6> createState() => _PortafoglioV6State();
}

class _PortafoglioV6State extends State<PortafoglioV6> {
  bool isPercent = false;
  final double colTicker = 60, colQty = 45, colPmc = 60, colVC = 75, colPrice = 65, colVM = 75;

  @override
  Widget build(BuildContext context) {
    var eurAssets = widget.assets.where((a) => a['cur'] == 'EUR').toList();
    var usdAssets = widget.assets.where((a) => a['cur'] == 'USD').toList();

    return Scaffold(
      appBar: AppBar(title: const Text("TITOLI V6"), actions: [
        if(widget.isRefreshing) const Center(child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))),
        IconButton(icon: const Icon(Icons.refresh), onPressed: widget.onRefresh),
        Switch(value: isPercent, onChanged: (v) => setState(() => isPercent = v)),
        const SizedBox(width: 10)
      ]),
      body: SingleChildScrollView(
        child: Column(children: [
          _buildRigidSection("SEZIONE EUR", eurAssets, false),
          _buildRigidSection("SEZIONE USD", usdAssets, true),
          _buildFinalSummaryRow(),
        ]),
      ),
    );
  }

  Widget _buildRigidSection(String title, List<Map<String, dynamic>> data, bool isUsd) {
    double totC = data.fold(0, (s, a) => s + (a['qty'] * a['pmc']));
    double totM = data.fold(0, (s, a) => s + (a['qty'] * a['lastPrice']));
    double totG = totM - totC;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: double.infinity, color: Colors.blueGrey.shade100, padding: const EdgeInsets.all(8), child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(children: [
          _rigidHeader(),
          const Divider(height: 1),
          ...data.map((a) => _rigidRow(a)),
          const Divider(height: 1, thickness: 1, color: Colors.black26),
          _rigidSubtotal(totC, totM, totG, false),
          if (isUsd) _rigidSubtotal(totC/widget.fx, totM/widget.fx, totG/widget.fx, true),
        ]),
      ),
      const SizedBox(height: 20),
    ]);
  }

  Widget _rigidHeader() {
    const styleH = TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        SizedBox(width: colTicker, child: const Text("Ticker", style: styleH)),
        SizedBox(width: colQty, child: const Text("Q.tà", textAlign: TextAlign.right, style: styleH)),
        SizedBox(width: colPmc, child: const Text("PMC", textAlign: TextAlign.right, style: styleH)),
        SizedBox(width: colVC, child: const Text("Val.Car", textAlign: TextAlign.right, style: styleH)),
        SizedBox(width: colPrice, child: const Text("Prezzo Mkt", textAlign: TextAlign.right, style: styleH)),
        SizedBox(width: colVM, child: const Text("Val.Mer", textAlign: TextAlign.right, style: styleH)),
        Expanded(child: const Text("G/L", textAlign: TextAlign.right, style: styleH)),
      ]),
    );
  }

  Widget _rigidRow(Map<String, dynamic> a) {
    double vC = a['qty'] * a['pmc'];
    double vM = a['qty'] * (a['lastPrice'] ?? 0.0);
    double g = vM - vC;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        SizedBox(width: colTicker, child: Text(a['ticker'], style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
        SizedBox(width: colQty, child: Text(a['qty'].toStringAsFixed(1), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
        SizedBox(width: colPmc, child: Text(a['pmc'].toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 10, color: Colors.blueGrey))),
        SizedBox(width: colVC, child: Text(vC.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
        SizedBox(width: colPrice, child: Text(a['lastPrice'].toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold))),
        SizedBox(width: colVM, child: Text(vM.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500))),
        Expanded(child: Text(isPercent ? "${(g/vC*100).toStringAsFixed(1)}%" : g.toStringAsFixed(0), textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: g >= 0 ? Colors.green : Colors.red))),
      ]),
    );
  }

  Widget _rigidSubtotal(double c, double m, double g, bool isEuroConv) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: colTicker + colQty + colPmc, child: Text(isEuroConv ? "Controval. €" : "SUBTOTALE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isEuroConv ? Colors.blueGrey : Colors.black))),
        SizedBox(width: colVC, child: Text(c.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
        SizedBox(width: colPrice, child: const SizedBox()),
        SizedBox(width: colVM, child: Text(m.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
        Expanded(child: Text(g.toStringAsFixed(0), textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: g >= 0 ? Colors.green : Colors.red))),
      ]),
    );
  }

  Widget _buildFinalSummaryRow() {
    double totC = widget.assets.fold(0, (s, a) => s + (a['cur'] == 'EUR' ? (a['qty']*a['pmc']) : (a['qty']*a['pmc']/widget.fx)));
    double totM = widget.assets.fold(0, (s, a) => s + (a['cur'] == 'EUR' ? (a['qty']*a['lastPrice']) : (a['qty']*a['lastPrice']/widget.fx)));
    double totG = totM - totC;

    return Container(
      margin: const EdgeInsets.only(top: 20, bottom: 40),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      color: const Color(0xFF0D47A1).withOpacity(0.05),
      child: Row(children: [
        SizedBox(width: colTicker + colQty + colPmc, child: const Text("TOTALE ASSET (€)", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11))),
        SizedBox(width: colVC, child: Text(totC.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
        SizedBox(width: colPrice, child: const SizedBox()),
        SizedBox(width: colVM, child: Text(totM.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
        Expanded(child: Text(totG.toStringAsFixed(2), textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: totG >= 0 ? Colors.green.shade700 : Colors.red.shade700))),
      ]),
    );
  }
}

// --- 3. PAGINA CASSA ---
class CassaPage extends StatefulWidget {
  final double cashEur, cashUsd;
  final Function(Transaction) onAction;
  final Function(double) onFxUpdate;
  const CassaPage({super.key, required this.cashEur, required this.cashUsd, required this.onAction, required this.onFxUpdate});
  @override State<CassaPage> createState() => _CassaPageState();
}

class _CassaPageState extends State<CassaPage> {
  final _amtCap = TextEditingController(), _amtFx = TextEditingController(), _rateFx = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("CASSA")),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _box("1. MOVIMENTI IN EURO (CAPITALE)", [
          TextField(controller: _amtCap, decoration: const InputDecoration(labelText: "Importo EUR"), keyboardType: TextInputType.number),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: ElevatedButton(onPressed: () => _handle(true), child: const Text("VERSAMENTO"))),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(onPressed: () => _handle(false), child: const Text("PRELIEVO"))),
          ])
        ]),
        _box("2. CAMBIO VALUTA (FOREX)", [
          TextField(controller: _amtFx, decoration: const InputDecoration(labelText: "Importo sorgente"), keyboardType: TextInputType.number),
          TextField(controller: _rateFx, decoration: const InputDecoration(labelText: "Tasso operazione"), keyboardType: TextInputType.number),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: ElevatedButton(onPressed: () => _fx(true), child: const Text("EUR ➔ USD"))),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(onPressed: () => _fx(false), child: const Text("USD ➔ EUR"))),
          ])
        ]),
      ]),
    );
  }
  Widget _box(String t, List<Widget> c) => Container(margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.all(15), decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0D47A1))), const Divider(), ...c]));
  void _handle(bool d) { widget.onAction(Transaction(date: DateTime.now(), type: d ? TransactionType.deposit : TransactionType.withdrawal, asset: "CAPITALE", qty: double.parse(_amtCap.text), price: 1, currency: "EUR")); _amtCap.clear(); }
  void _fx(bool e) {
    double a = double.parse(_amtFx.text), r = double.parse(_rateFx.text);
    if(e) { widget.onAction(Transaction(date: DateTime.now(), type: TransactionType.exchange, asset: "TO_USD", qty: a, price: r, currency: "EUR")); widget.onAction(Transaction(date: DateTime.now(), type: TransactionType.exchange, asset: "FROM_EUR", qty: a*r, price: 1, currency: "USD")); }
    else { widget.onAction(Transaction(date: DateTime.now(), type: TransactionType.exchange, asset: "TO_EUR", qty: a, price: r, currency: "USD")); widget.onAction(Transaction(date: DateTime.now(), type: TransactionType.exchange, asset: "FROM_USD", qty: a/r, price: 1, currency: "EUR")); }
    _amtFx.clear(); _rateFx.clear();
  }
}

// --- 4. PAGINA TRADE ---
class TradePage extends StatefulWidget {
  final Function(Transaction) onTrade;
  const TradePage({super.key, required this.onTrade});
  @override State<TradePage> createState() => _TradePageState();
}

class _TradePageState extends State<TradePage> {
  DateTime _date = DateTime.now();
  int _typeIndex = 0; // 0: BUY, 1: SELL, 2: DIVIDEND
  String _cur = 'EUR';
  final _t = TextEditingController(), _q = TextEditingController(), _p = TextEditingController(), _f = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("TRADE & DIVIDENDI")),
      body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 0, label: Text("BUY")), ButtonSegment(value: 1, label: Text("SELL")), ButtonSegment(value: 2, label: Text("DIVIDEND"))],
          selected: {_typeIndex},
          onSelectionChanged: (s) => setState(() => _typeIndex = s.first),
        ),
        const SizedBox(height: 20),
        ListTile(title: Text("Data: ${DateFormat('dd/MM/yyyy').format(_date)}"), trailing: const Icon(Icons.calendar_today), onTap: () async { DateTime? d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100)); if(d != null) setState(() => _date = d); }),
        TextField(controller: _t, decoration: const InputDecoration(labelText: "Ticker (es: AAPL o ENI.MI)")),
        Row(children: [
          Expanded(child: TextField(controller: _q, decoration: InputDecoration(labelText: _typeIndex == 2 ? "Importo Netto" : "Quantità"), keyboardType: TextInputType.number)),
          const SizedBox(width: 20),
          DropdownButton<String>(value: _cur, items: const [DropdownMenuItem(value: 'EUR', child: Text("EUR")), DropdownMenuItem(value: 'USD', child: Text("USD"))], onChanged: (v) => setState(() => _cur = v!)),
        ]),
        if(_typeIndex != 2) ...[
          TextField(controller: _p, decoration: const InputDecoration(labelText: "Prezzo Unitario"), keyboardType: TextInputType.number),
          TextField(controller: _f, decoration: const InputDecoration(labelText: "Commissioni"), keyboardType: TextInputType.number),
        ],
        const SizedBox(height: 30),
        SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () {
          widget.onTrade(Transaction(
            date: _date, 
            type: _typeIndex == 0 ? TransactionType.buy : (_typeIndex == 1 ? TransactionType.sell : TransactionType.dividend),
            asset: _t.text.toUpperCase(), 
            qty: double.parse(_q.text),
            price: _typeIndex == 2 ? 1 : double.parse(_p.text), 
            fees: _typeIndex == 2 ? 0 : (double.tryParse(_f.text) ?? 0), 
            currency: _cur,
          ));
          _t.clear(); _q.clear(); _p.clear(); _f.clear();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Operazione registrata!")));
        }, child: const Text("REGISTRA"))),
      ])),
    );
  }
}

// --- 5. STORICO ---
class StoricoPage extends StatelessWidget {
  final List<Transaction> history;
  final Function(int) onDelete;
  const StoricoPage({super.key, required this.history, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final list = history.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text("STORICO")),
      body: ListView.builder(
        itemCount: list.length,
        itemBuilder: (c, i) {
          final t = list[i];
          return ListTile(
            dense: true,
            title: Text("${t.asset} | ${t.type.name.toUpperCase()}"),
            subtitle: Text("${DateFormat('dd/MM/yy').format(t.date)} - ${t.qty} @ ${t.price} ${t.currency}"),
            trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 18), onPressed: () => onDelete(history.length - 1 - i)),
          );
        },
      ),
    );
  }
}