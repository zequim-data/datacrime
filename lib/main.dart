import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:convert';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runZonedGuarded(() {
    runApp(const MaterialApp(
      home: MapScreen(),
      debugShowCheckedModeBanner: false,
    ));
  }, (error, stackTrace) {
    print("ERRO CRÍTICO CAPTURADO: $error");
    runApp(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.red.shade900,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: SingleChildScrollView(
              child: Text("FALHA NO APP:\n$error\n\n$stackTrace",
                  style: const TextStyle(
                      color: Colors.white, fontFamily: 'Courier')),
            ),
          ),
        ),
      ),
    ));
  });
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _controller = Completer();
  final TextEditingController _searchController = TextEditingController();

  // --- VARIÁVEIS PARA COMPARAÇÃO (NOVA ABA) ---
  final TextEditingController _endereco1Controller = TextEditingController();
  final TextEditingController _endereco2Controller = TextEditingController();
  Map<String, dynamic>? _resultadoComparacao;
  bool _comparando = false;

  // --- CONFIGURAÇÕES ---
  final String googleApiKey = "AIzaSyDszIW2iBdyxbIo_NavRtpReKn8Lkrcbr8";
  final String baseUrl =
      "https://zecchin-api-997663776889.southamerica-east1.run.app";

  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  LatLng? pontoSelecionado;

  double raioBusca = 300.0;
  String filtroAno = "2025";
  int menuIndex =
      0; // 0: Celular, 1: Veiculo, 2: Acidente, 3: Criminal, 4: Comparar

  Map<String, int> estatisticasMarcas = {};
  bool carregando = false;

  String get tipoCrimeParam {
    if (menuIndex == 0) return "celular";
    if (menuIndex == 1) return "veiculo";
    if (menuIndex == 2) return "acidente";
    return "criminal";
  }

  Color get themeColor => Colors.orangeAccent;

  Widget _bloqueioMapa({required Widget child}) {
    return PointerInterceptor(child: child);
  }

  // --- FUNÇÕES DE BUSCA MAPA ---
  Future<void> _buscarPorTexto(String endereco) async {
    if (endereco.isEmpty) return;
    setState(() => carregando = true);
    FocusScope.of(context).unfocus();

    // Reutilizando a função robusta de geocoding
    LatLng? destino = await _getLatLon(endereco);

    if (destino != null) {
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(CameraUpdate.newLatLngZoom(destino, 16));
      buscarCrimes(destino);
    } else {
      _snack("Endereço não encontrado.");
    }
    setState(() => carregando = false);
  }

  // Função Genérica para Geocodificar (Usada na busca e na comparação)
  Future<LatLng?> _getLatLon(String endereco) async {
    final url = Uri.parse(
        "https://maps.googleapis.com/maps/api/geocode/json?address=$endereco&components=country:BR|administrative_area:SP&key=$googleApiKey");
    try {
      final response = await http.get(url);
      final data = json.decode(response.body);
      if (data['status'] == 'OK') {
        final loc = data['results'][0]['geometry']['location'];
        return LatLng(loc['lat'], loc['lng']);
      }
    } catch (e) {
      print("Erro Geocoding: $e");
    }
    return null;
  }

  void _atualizarCirculo() {
    if (pontoSelecionado == null) return;
    setState(() {
      _circles = {
        Circle(
          circleId: const CircleId("raio_analise"),
          center: pontoSelecionado!,
          radius: raioBusca,
          fillColor: Colors.red.withOpacity(0.15),
          strokeColor: Colors.red,
          strokeWidth: 2,
        )
      };
    });
  }

  Future<BitmapDescriptor> _criarIconeCustomizado(
      String texto, Color cor) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = cor.withOpacity(1.0);
    final int size = 30;
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint);
    Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, borderPaint);
    if (int.tryParse(texto) != null && int.parse(texto) > 1) {
      TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
      painter.text = TextSpan(
          text: texto,
          style: const TextStyle(
              fontSize: 11, color: Colors.black, fontWeight: FontWeight.bold));
      painter.layout();
      painter.paint(canvas,
          Offset((size - painter.width) / 2, (size - painter.height) / 2));
    }
    final ui.Image img =
        await pictureRecorder.endRecording().toImage(size, size);
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  Future<void> buscarCrimes(LatLng pos) async {
    setState(() {
      pontoSelecionado = pos;
      carregando = true;
      _atualizarCirculo();
    });
    try {
      final String linkReq =
          '$baseUrl/crimes?lat=${pos.latitude}&lon=${pos.longitude}&raio=${raioBusca.toInt()}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam';
      final response = await http.get(Uri.parse(linkReq));
      if (response.statusCode != 200) {
        _snack("Erro Servidor (${response.statusCode})");
        setState(() => carregando = false);
        return;
      }

      final Map<String, dynamic> responseData = json.decode(response.body);
      final List<dynamic> crimes = responseData['data'] ?? [];
      if (crimes.isEmpty)
        _snack("Zero registros de '$tipoCrimeParam' para '$filtroAno' aqui.");

      Map<String, int> counts = {};
      Map<String, int> clusterCount = {};
      Map<String, dynamic> clusterData = {};

      for (var c in crimes) {
        String latLonKey = "${c['lat']}_${c['lon']}";
        int qtd = c['quantidade'] ?? 1;
        clusterCount[latLonKey] = (clusterCount[latLonKey] ?? 0) + qtd;
        clusterData[latLonKey] = c;
        String tipo = (c['tipo'] ?? 'N/I').toString().toUpperCase();
        counts[tipo] = (counts[tipo] ?? 0) + 1;
      }

      Set<Marker> newMarkers = {};
      for (var key in clusterCount.keys) {
        var dados = clusterData[key];
        int totalCluster = clusterCount[key]!;
        double l = double.parse(dados['lat'].toString());
        double ln = double.parse(dados['lon'].toString());
        Color corMarker = themeColor;
        if (menuIndex == 2) {
          String sev = dados['severidade'] ?? 'LEVE';
          if (sev == 'FATAL') corMarker = Colors.red[900]!;
        }
        BitmapDescriptor icon =
            await _criarIconeCustomizado("$totalCluster", corMarker);
        newMarkers.add(Marker(
            markerId: MarkerId(key),
            position: LatLng(l, ln),
            icon: icon,
            onTap: () => buscarDetalhesPonto(LatLng(l, ln))));
      }
      setState(() {
        _markers = newMarkers;
        estatisticasMarcas = counts;
      });
    } catch (e) {
      _snack("Erro App: $e");
    } finally {
      setState(() => carregando = false);
    }
  }

  Future<void> buscarDetalhesPonto(LatLng pos) async {
    setState(() => carregando = true);
    final url = Uri.parse(
        '$baseUrl/detalhes?lat=${pos.latitude}&lon=${pos.longitude}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        String body = utf8.decode(response.bodyBytes);
        final Map<String, dynamic> responseData = json.decode(body);
        _exibirGavetaDetalhes(responseData['data'] ?? []);
      } else {
        _snack("Erro Detalhes: ${response.statusCode}");
      }
    } catch (e) {
      _snack("Erro ao buscar detalhes.");
    } finally {
      setState(() => carregando = false);
    }
  }

  void _exibirGavetaDetalhes(List<dynamic> lista) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.95),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) => PointerInterceptor(
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.95,
          minChildSize: 0.4,
          expand: false,
          builder: (_, scroll) => Container(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(10))),
              const SizedBox(height: 15),
              Text("${lista.length} REGISTROS AQUI",
                  style: TextStyle(
                      color: themeColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
              Divider(color: themeColor, height: 25),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: lista.length,
                  itemBuilder: (context, i) {
                    final c = lista[i];
                    bool isAcidente = menuIndex == 2;
                    bool isCriminal = menuIndex == 3;
                    return Card(
                      color: Colors.white.withOpacity(0.1),
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      child: ExpansionTile(
                        iconColor: themeColor,
                        collapsedIconColor: Colors.white30,
                        title: Text("${c['rubrica'] ?? 'OCORRÊNCIA'}",
                            style: TextStyle(
                                color: themeColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                        subtitle: Text("${c['data'] ?? ''}",
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 11)),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(15),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (isAcidente) ...[
                                    Wrap(
                                        spacing: 15,
                                        runSpacing: 10,
                                        alignment: WrapAlignment.center,
                                        children: [
                                          _iconStat(Icons.directions_car,
                                              c['autos'], "Carros"),
                                          _iconStat(Icons.two_wheeler,
                                              c['motos'], "Motos"),
                                          _iconStat(Icons.directions_walk,
                                              c['pedestres'], "Pedestres"),
                                          _iconStat(Icons.pedal_bike,
                                              c['bikes'], "Bikes"),
                                          _iconStat(Icons.directions_bus,
                                              c['onibus'], "Ônibus"),
                                          _iconStat(Icons.local_shipping,
                                              c['caminhoes'], "Caminhões"),
                                          _iconStat(Icons.help_outline,
                                              c['outros'], "Outros"),
                                        ]),
                                    const SizedBox(height: 15),
                                    if (c['lista_veiculos'] != null &&
                                        (c['lista_veiculos'] as List)
                                            .isNotEmpty) ...[
                                      Text("VEÍCULOS:",
                                          style: TextStyle(
                                              color: themeColor,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold)),
                                      const SizedBox(height: 5),
                                      ...(c['lista_veiculos'] as List)
                                          .map((v) => _cardVeiculo(v))
                                          .toList(),
                                      const SizedBox(height: 15),
                                    ],
                                    if (c['lista_pessoas'] != null &&
                                        (c['lista_pessoas'] as List)
                                            .isNotEmpty) ...[
                                      Text("VÍTIMAS:",
                                          style: TextStyle(
                                              color: themeColor,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold)),
                                      const SizedBox(height: 5),
                                      ...(c['lista_pessoas'] as List)
                                          .map((p) => _cardPessoa(p))
                                          .toList(),
                                    ],
                                    const Divider(
                                        color: Colors.white24, height: 20),
                                    _itemInfo("Local:", c['local_texto']),
                                  ] else ...[
                                    if (isCriminal)
                                      _itemInfo("Natureza:", c['marca'])
                                    else
                                      _itemInfo("Marca:", c['marca']),
                                    if (menuIndex == 1) ...[
                                      _itemInfo("Placa:", c['placa']),
                                      _itemInfo("Cor:", c['cor']),
                                    ],
                                    _itemInfo("Endereço:", c['local_texto']),
                                  ]
                                ]),
                          )
                        ],
                      ),
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _cardVeiculo(dynamic v) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(5),
          border: Border(left: BorderSide(color: themeColor, width: 2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("${v['modelo'] ?? 'N/I'} (${v['ano_fab'] ?? '-'})",
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
        Text("Cor: ${v['cor'] ?? '-'} • Tipo: ${v['tipo'] ?? '-'}",
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }

  Widget _cardPessoa(dynamic p) {
    Color cor = Colors.blue;
    String l = (p['lesao'] ?? '').toString().toUpperCase();
    if (l.contains("FATAL") || l.contains("MORTO")) cor = Colors.red;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(5),
          border: Border(left: BorderSide(color: cor, width: 2))),
      child: Text(
          "${p['tipo_vitima']} • ${p['sexo']} • ${p['idade'] ?? '-'} anos\nLesão: ${p['lesao']} • Profissão: ${p['profissao'] ?? '-'}",
          style: const TextStyle(color: Colors.white, fontSize: 11)),
    );
  }

  Widget _iconStat(IconData icon, dynamic count, String label) {
    int val = count is int ? count : (count is double ? count.toInt() : 0);
    return Column(children: [
      Icon(icon, color: Colors.white, size: 20),
      Text(val.toString(),
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9))
    ]);
  }

  Widget _itemInfo(String label, String? v) {
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("$label ",
              style: TextStyle(
                  color: themeColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
          Expanded(
              child: Text(v,
                  style: const TextStyle(color: Colors.white, fontSize: 12)))
        ]));
  }

  Future<void> _gps() async {
    LocationPermission p = await Geolocator.requestPermission();
    if (p != LocationPermission.denied) {
      Position pos = await Geolocator.getCurrentPosition();
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 15));
      buscarCrimes(LatLng(pos.latitude, pos.longitude));
    }
  }

  void _snack(String t) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(t), backgroundColor: Colors.red));

  // --- NOVA FUNCIONALIDADE: EXECUTA COMPARAÇÃO ---
  Future<void> _executarComparacao() async {
    if (_endereco1Controller.text.isEmpty ||
        _endereco2Controller.text.isEmpty) {
      _snack("Preencha os dois locais!");
      return;
    }
    setState(() => _comparando = true);
    FocusScope.of(context).unfocus();

    try {
      LatLng? p1 = await _getLatLon(_endereco1Controller.text);
      if (p1 == null)
        throw "Local A não encontrado (Tente ser mais específico, ex: Rua Augusta, SP).";
      LatLng? p2 = await _getLatLon(_endereco2Controller.text);
      if (p2 == null) throw "Local B não encontrado.";

      final url = Uri.parse(
          '$baseUrl/comparar?lat1=${p1.latitude}&lon1=${p1.longitude}&lat2=${p2.latitude}&lon2=${p2.longitude}&filtro=$filtroAno');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        setState(() => _resultadoComparacao = json.decode(response.body));
      } else {
        throw "Erro na API: ${response.statusCode}";
      }
    } catch (e) {
      _snack("Erro: $e");
    } finally {
      setState(() => _comparando = false);
    }
  }

  // --- UI DA TELA DE COMPARAÇÃO ---
  Widget _buildTelaComparacao() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        const SizedBox(height: 40),
        Text("DUELO DE LOCAIS",
            style: TextStyle(
                color: themeColor,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5)),
        const Text("Compare a segurança de dois endereços (Raio 500m)",
            style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 20),
        _inputLocal(_endereco1Controller, "Local A (Ex: Av Paulista, 1000)"),
        const SizedBox(height: 10),
        _inputLocal(_endereco2Controller, "Local B (Ex: Rua Augusta, 500)"),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          icon: const Icon(Icons.analytics, color: Colors.black),
          label: const Text("COMPARAR",
              style:
                  TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          style: ElevatedButton.styleFrom(
              backgroundColor: themeColor,
              padding:
                  const EdgeInsets.symmetric(horizontal: 50, vertical: 15)),
          onPressed: _executarComparacao,
        ),
        const SizedBox(height: 20),
        if (_comparando)
          const CircularProgressIndicator()
        else if (_resultadoComparacao != null)
          _buildTabelaResultados(),
      ]),
    );
  }

  Widget _inputLocal(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: hint,
        labelStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: Colors.grey[900],
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: themeColor)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.white24)),
      ),
    );
  }

  Widget _buildTabelaResultados() {
    var r = _resultadoComparacao!;
    var a = r['local_a'];
    var b = r['local_b'];
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white10)),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text("CRIMES (500m)",
                style: TextStyle(color: Colors.white54, fontSize: 10)),
            Text("LOCAL A",
                style:
                    TextStyle(color: themeColor, fontWeight: FontWeight.bold)),
            Text("LOCAL B",
                style: TextStyle(
                    color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          ]),
          const Divider(color: Colors.white24),
          _linhaComp("Roubos Celular", a['celular'], b['celular']),
          _linhaComp("Roubos Veículo", a['veiculo'], b['veiculo']),
          _linhaComp("Ocorrências Policiais", a['criminal'], b['criminal']),
          _linhaComp("Acidentes", a['acidente'], b['acidente']),
          const Divider(color: Colors.white24),
          _linhaComp("TOTAL", r['total_a'], r['total_b'], destaque: true),
        ]),
      ),
    );
  }

  Widget _linhaComp(String label, int v1, int v2, {bool destaque = false}) {
    Color corV1 = Colors.white;
    Color corV2 = Colors.white;
    if (v1 < v2) {
      corV1 = Colors.greenAccent;
      corV2 = Colors.redAccent;
    } else if (v2 < v1) {
      corV1 = Colors.redAccent;
      corV2 = Colors.greenAccent;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(
            child: Text(label,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight:
                        destaque ? FontWeight.bold : FontWeight.normal))),
        Text("$v1",
            style: TextStyle(
                color: destaque ? corV1 : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        const SizedBox(width: 40),
        Text("$v2",
            style: TextStyle(
                color: destaque ? corV2 : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: menuIndex,
        backgroundColor: Colors.black,
        selectedItemColor: themeColor,
        unselectedItemColor: Colors.white60,
        type: BottomNavigationBarType.fixed,
        onTap: (i) {
          setState(() {
            menuIndex = i;
            _markers = {};
            if (pontoSelecionado != null && i != 4)
              buscarCrimes(pontoSelecionado!);
          });
        },
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.phone_android), label: "Celulares"),
          BottomNavigationBarItem(
              icon: Icon(Icons.directions_car), label: "Veículos"),
          BottomNavigationBarItem(
              icon: Icon(Icons.warning_amber), label: "Acidentes"),
          BottomNavigationBarItem(
              icon: Icon(Icons.local_police), label: "Polícia"),
          BottomNavigationBarItem(
              icon: Icon(Icons.compare_arrows), label: "Comparar"), // NOVO
        ],
      ),
      body: menuIndex == 4
          ? _buildTelaComparacao()
          : Stack(children: [
              GoogleMap(
                mapType: MapType.normal,
                initialCameraPosition: const CameraPosition(
                    target: LatLng(-23.5505, -46.6333), zoom: 14.4746),
                onMapCreated: (c) {
                  _controller.complete(c);
                },
                markers: _markers,
                circles: _circles,
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                onTap: buscarCrimes,
              ),
              Positioned(
                  top: 50,
                  left: 15,
                  right: 15,
                  child: _bloqueioMapa(
                      child: Container(
                          decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(30),
                              border: Border.all(
                                  color: themeColor.withOpacity(0.5))),
                          child: TextField(
                              controller: _searchController,
                              onSubmitted: _buscarPorTexto,
                              textInputAction: TextInputAction.search,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                  hintText: "Digite endereço ou CEP...",
                                  hintStyle: const TextStyle(
                                      color: Colors.white38, fontSize: 13),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 15, horizontal: 20),
                                  suffixIcon: IconButton(
                                      icon:
                                          Icon(Icons.search, color: themeColor),
                                      onPressed: () => _buscarPorTexto(
                                          _searchController.text))))))),
              Positioned(
                  top: 120,
                  left: 15,
                  right: 15,
                  child: _bloqueioMapa(
                      child: Column(children: [
                    Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(15),
                            border:
                                Border.all(color: themeColor.withOpacity(0.5))),
                        child: Column(children: [
                          Text("RAIO: ${raioBusca.toInt()} METROS",
                              style: TextStyle(
                                  color: themeColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11)),
                          Slider(
                              value: raioBusca,
                              min: 10,
                              max: 1000,
                              divisions: 99,
                              activeColor: themeColor,
                              inactiveColor: Colors.grey[800],
                              onChanged: (v) => setState(() {
                                    raioBusca = v;
                                    _atualizarCirculo();
                                  }),
                              onChangeEnd: (v) {
                                if (pontoSelecionado != null)
                                  buscarCrimes(pontoSelecionado!);
                              })
                        ])),
                    const SizedBox(height: 10),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      _btn("2025", "2025"),
                      _btn("3 ANOS", "3_anos"),
                      _btn("5 ANOS", "5_anos")
                    ]),
                  ]))),
              Positioned(
                  bottom: 20,
                  left: 15,
                  child: _bloqueioMapa(
                      child: FloatingActionButton(
                          backgroundColor: themeColor,
                          onPressed: _gps,
                          child: const Icon(Icons.my_location,
                              color: Colors.black)))),
              if (estatisticasMarcas.isNotEmpty)
                Positioned(
                    bottom: 20,
                    right: 15,
                    child: _bloqueioMapa(
                        child: Container(
                            width: 200,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.9),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                    color: themeColor.withOpacity(0.5))),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                      menuIndex == 2
                                          ? "TOP OCORRÊNCIAS"
                                          : menuIndex == 3
                                              ? "TOP NATUREZAS"
                                              : "TOP MARCAS",
                                      style: TextStyle(
                                          color: themeColor,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                  Divider(color: themeColor, height: 15),
                                  ...(estatisticasMarcas.entries.toList()
                                        ..sort((a, b) =>
                                            b.value.compareTo(a.value)))
                                      .take(5)
                                      .map((e) => Padding(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 3),
                                          child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Flexible(
                                                    child: Text(e.key,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 10))),
                                                Text("${e.value}",
                                                    style: TextStyle(
                                                        color: themeColor,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 10))
                                              ])))
                                      .toList(),
                                  const Divider(
                                      color: Colors.white24, height: 15),
                                  const Text("Toque nos ícones para detalhes",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 9,
                                          fontStyle: FontStyle.italic))
                                ])))),
              if (carregando)
                Center(
                    child: CircularProgressIndicator(
                        color: themeColor, strokeWidth: 8)),
            ]),
    );
  }

  Widget _btn(String l, String v) {
    bool s = filtroAno == v;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: s ? themeColor : Colors.black.withOpacity(0.8),
                foregroundColor: s ? Colors.black : Colors.grey,
                side: BorderSide(
                    color:
                        s ? Colors.transparent : themeColor.withOpacity(0.5))),
            onPressed: () {
              setState(() => filtroAno = v);
              if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!);
            },
            child: Text(l,
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold))));
  }
}
