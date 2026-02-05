import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:convert';

void main() => runApp(const MaterialApp(
      home: MapScreen(),
      debugShowCheckedModeBanner: false,
    ));

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  List<Marker> crimeMarkers = [];
  List<CircleMarker> searchRadiusCircle = [];
  LatLng? pontoSelecionado;

  double raioBusca = 300.0;
  String filtroAno = "2025";
  int menuIndex = 0; // 0 = Celulares, 1 = Veículos
  Map<String, int> estatisticasMarcas = {};
  bool carregando = false;

  // Substitua o link do ngrok pelo seu novo link do Google Cloud
  final String baseUrl =
      "https://zecchin-api-997663776889.southamerica-east1.run.app";

  String get tipoCrimeParam => menuIndex == 0 ? "celular" : "veiculo";

  // --- 1. BUSCA DE DETALHES ---
  Future<void> buscarDetalhesPonto(double lat, double lon) async {
    setState(() => carregando = true);
    final url = Uri.parse(
        '$baseUrl/detalhes?lat=$lat&lon=$lon&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');

    try {
      final response =
          await http.get(url, headers: {"ngrok-skip-browser-warning": "true"});
      if (response.statusCode == 200) {
        _exibirGavetaDetalhes(json.decode(response.body)['data']);
      }
    } catch (e) {
      _snack("Erro ao buscar detalhes no BigQuery.");
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
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
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
            Text("${lista.length} OCORRÊNCIAS NESTE PONTO",
                style: const TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            const Divider(color: Colors.amber, height: 25),
            Expanded(
                child: ListView.builder(
              controller: scroll,
              itemCount: lista.length,
              itemBuilder: (context, i) {
                final c = lista[i];
                return Card(
                  color: Colors.white.withOpacity(0.05),
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  child: ExpansionTile(
                    iconColor: Colors.cyan,
                    collapsedIconColor: Colors.white,
                    title: Text("${c['rubrica']}",
                        style: const TextStyle(
                            color: Colors.cyan,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    subtitle: Text("${c['data']} - ${c['hora']}",
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(15),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _itemInfo("Marca:", c['marca']),
                              if (menuIndex == 1) ...[
                                _itemInfo("Placa:", c['placa']),
                                _itemInfo("Cor:", c['cor']),
                              ],
                              _itemInfo("Conduta:", c['conduta']),
                              _itemInfo("Tipo do Local:", c['local']),
                            ]),
                      )
                    ],
                  ),
                );
              },
            )),
          ]),
        ),
      ),
    );
  }

  Widget _itemInfo(String label, String? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text.rich(TextSpan(children: [
          TextSpan(
              text: "$label ",
              style: const TextStyle(
                  color: Colors.amber,
                  fontWeight: FontWeight.bold,
                  fontSize: 12)),
          TextSpan(
              text: v ?? "N/I",
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ])),
      );

  // --- 2. BUSCA GERAL ---
  Future<void> buscarCrimes(double lat, double lon) async {
    setState(() {
      pontoSelecionado = LatLng(lat, lon);
      carregando = true;
      searchRadiusCircle = [
        CircleMarker(
            point: LatLng(lat, lon),
            radius: raioBusca,
            useRadiusInMeter: true,
            color: Colors.cyan.withOpacity(0.05),
            borderColor: Colors.cyan.withOpacity(0.3),
            borderStrokeWidth: 2)
      ];
    });

    try {
      final url = Uri.parse(
          '$baseUrl/crimes?lat=$lat&lon=$lon&raio=${raioBusca.toInt()}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');
      final response =
          await http.get(url, headers: {"ngrok-skip-browser-warning": "true"});
      if (response.statusCode == 200) {
        final List<dynamic> crimes = json.decode(response.body)['data'] ?? [];
        Map<String, int> counts = {};
        Map<String, int> agrupados = {};

        for (var c in crimes) {
          counts[c['tipo'].toString().toUpperCase()] =
              (counts[c['tipo'].toString().toUpperCase()] ?? 0) + 1;
          String chave = "${c['lat']},${c['lon']}";
          agrupados[chave] = (agrupados[chave] ?? 0) + 1;
        }

        setState(() {
          estatisticasMarcas = counts;
          crimeMarkers = agrupados.entries.map((e) {
            final l = double.parse(e.key.split(',')[0]);
            final ln = double.parse(e.key.split(',')[1]);
            return Marker(
              point: LatLng(l, ln),
              width: 26,
              height: 26,
              child: GestureDetector(
                onTap: () => buscarDetalhesPonto(l, ln),
                child: Container(
                  decoration: BoxDecoration(
                    color: e.value > 10 ? Colors.red : Colors.yellow,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black, width: 2),
                  ),
                  child: Center(
                      child: Text("${e.value}",
                          style: const TextStyle(
                              fontSize: 9, fontWeight: FontWeight.bold))),
                ),
              ),
            );
          }).toList();
        });
      }
    } catch (e) {
      _snack("Erro de conexão com o backend.");
    } finally {
      setState(() => carregando = false);
    }
  }

  // --- 3. FERRAMENTAS (GPS RESTAURADO) ---
  Future<void> _gps() async {
    setState(() => carregando = true);
    LocationPermission p = await Geolocator.requestPermission();
    if (p != LocationPermission.denied) {
      Position pos = await Geolocator.getCurrentPosition();
      _mapController.move(LatLng(pos.latitude, pos.longitude), 15);
      buscarCrimes(pos.latitude, pos.longitude);
    }
    setState(() => carregando = false);
  }

  Future<void> _buscarEnd(String q) async {
    if (q.isEmpty) return;
    setState(() => carregando = true);
    final r = await http.get(Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$q&format=json&limit=1'));
    final d = json.decode(r.body);
    if (d.isNotEmpty) {
      double la = double.parse(d[0]['lat']), lo = double.parse(d[0]['lon']);
      _mapController.move(LatLng(la, lo), 15);
      buscarCrimes(la, lo);
    }
    setState(() => carregando = false);
  }

  @override
  Widget build(BuildContext context) {
    Color themeColor = menuIndex == 0 ? Colors.cyan : Colors.greenAccent;

    return Scaffold(
      backgroundColor: Colors.black,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: menuIndex,
        backgroundColor: Colors.black,
        selectedItemColor: themeColor,
        unselectedItemColor: Colors.white30,
        onTap: (i) {
          setState(() {
            menuIndex = i;
            crimeMarkers = [];
            estatisticasMarcas = {};
          });
          if (pontoSelecionado != null)
            buscarCrimes(
                pontoSelecionado!.latitude, pontoSelecionado!.longitude);
        },
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.phone_android), label: "Celulares"),
          BottomNavigationBarItem(
              icon: Icon(Icons.directions_car), label: "Veículos"),
        ],
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
              initialCenter: LatLng(-23.5505, -46.6333),
              initialZoom: 15,
              onTap: (tp, pt) => buscarCrimes(pt.latitude, pt.longitude)),
          children: [
            TileLayer(
                urlTemplate:
                    'https://{s}.basemaps.cartocdn.com/rastertiles/voyager_labels_under/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd']),
            CircleLayer(circles: searchRadiusCircle),
            MarkerLayer(markers: [
              if (pontoSelecionado != null)
                Marker(
                    point: pontoSelecionado!,
                    width: 60,
                    height: 60,
                    child:
                        Icon(Icons.location_on, color: themeColor, size: 45)),
              ...crimeMarkers
            ]),
          ],
        ),
        Positioned(top: 50, left: 15, right: 15, child: _searchUI()),
        Positioned(
            top: 120, left: 15, right: 15, child: _controlsUI(themeColor)),

        // --- BOTÃO GPS RESTAURADO ---
        Positioned(
            bottom: 20,
            left: 15,
            child: FloatingActionButton(
                backgroundColor: themeColor,
                onPressed: _gps,
                child: const Icon(Icons.my_location, color: Colors.black))),

        if (estatisticasMarcas.isNotEmpty)
          Positioned(bottom: 20, right: 15, child: _statsUI(themeColor)),
        if (carregando)
          const Center(
              child: CircularProgressIndicator(
                  color: Colors.amber, strokeWidth: 8)),
      ]),
    );
  }

  Widget _searchUI() => Container(
        decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.9),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.amber.withOpacity(0.5))),
        child: TextField(
          controller: _searchController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
              hintText: "Rua, Bairro ou CEP...",
              hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
              prefixIcon: Icon(Icons.search, color: Colors.amber),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 15)),
          onSubmitted: (v) => _buscarEnd(v),
        ),
      );

  Widget _controlsUI(Color color) => Column(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.85),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: color.withOpacity(0.5))),
          child: Column(children: [
            Text(
                raioBusca >= 1000
                    ? "RAIO DE VARREDURA: 1.0 KM"
                    : "RAIO DE VARREDURA: ${raioBusca.toInt()} METROS",
                style: TextStyle(
                    color: color, fontWeight: FontWeight.bold, fontSize: 11)),
            Slider(
                value: raioBusca,
                min: 10,
                max: 1000,
                divisions: 99,
                activeColor: color,
                onChanged: (v) => setState(() => raioBusca = v),
                onChangeEnd: (v) {
                  if (pontoSelecionado != null)
                    buscarCrimes(pontoSelecionado!.latitude,
                        pontoSelecionado!.longitude);
                }),
          ]),
        ),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _btn("2025", "2025"),
          _btn("3 ANOS", "3_anos"),
          _btn("5 ANOS", "5_anos")
        ]),
      ]);

  Widget _btn(String l, String v) {
    bool s = filtroAno == v;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: s ? Colors.amber : Colors.grey[900]),
            onPressed: () {
              setState(() => filtroAno = v);
              if (pontoSelecionado != null)
                buscarCrimes(
                    pontoSelecionado!.latitude, pontoSelecionado!.longitude);
            },
            child: Text(l,
                style: TextStyle(
                    color: s ? Colors.black : Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold))));
  }

  Widget _statsUI(Color color) {
    // Ordenação mantida: do maior para o menor
    var sort = estatisticasMarcas.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      width: 200, // Aumentado de 140 para 200 para caber nomes como FIAT/STRADA
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.amber.withOpacity(0.5))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text("TOP MARCAS/MODELOS",
            style: TextStyle(
                color: Colors.amber,
                fontSize: 10,
                fontWeight: FontWeight.bold)),
        const Divider(color: Colors.amber, height: 15),
        ...sort.take(5).map((e) => Padding(
              // Aumentado para o Top 5, já que temos mais espaço
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // FLEXIBLE impede que o texto empurre o número para fora da tela
                    Flexible(
                      child: Text(e.key, // Removido o substring(0, 8)
                          overflow: TextOverflow
                              .ellipsis, // Adiciona "..." se ainda assim for longo
                          maxLines: 1,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10)),
                    ),
                    const SizedBox(width: 8),
                    Text("${e.value}",
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 10))
                  ]),
            )),
      ]),
    );
  }

  void _snack(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
}
