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

  // --- CONTROLES ORIGINAIS RESTAURADOS ---
  double raioBusca = 300.0; // Slider de distância
  String filtroAno = "2025";
  int menuIndex = 0; // 0=Celular, 1=Veículo, 2=Acidente
  Map<String, int> estatisticasMarcas = {};
  bool carregando = false;

  final String baseUrl =
      "https://zecchin-api-997663776889.southamerica-east1.run.app";

  // CORREÇÃO: Mapeia corretamente as 3 abas para o backend
  String get tipoCrimeParam {
    if (menuIndex == 0) return "celular";
    if (menuIndex == 1) return "veiculo";
    return "acidente";
  }

  // --- 1. BUSCA DE DETALHES (PLACA E COR RESTAURADOS) ---
  Future<void> buscarDetalhesPonto(double lat, double lon) async {
    setState(() => carregando = true);
    final url = Uri.parse(
        '$baseUrl/detalhes?lat=$lat&lon=$lon&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');

    try {
      final response =
          await http.get(url, headers: {"ngrok-skip-browser-warning": "true"});
      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        _exibirGavetaDetalhes(responseData['data'] ?? []);
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
                    title: Text("${c['rubrica'] ?? 'OCORRÊNCIA'}",
                        style: const TextStyle(
                            color: Colors.cyan,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    subtitle: Text("${c['data'] ?? 'DATA N/I'}",
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(15),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _itemInfo("Marca/Tipo:", c['marca']),
                              // RESTAURADO: Detalhes específicos de Veículos SSP
                              if (menuIndex == 1) ...[
                                _itemInfo("Placa:", c['placa']),
                                _itemInfo("Cor:", c['cor']),
                              ],
                              _itemInfo("Localização:", c['local'] ?? "N/I"),
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

  // --- 2. BUSCA GERAL (RAIO DE VARREDURA) ---
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
        final Map<String, dynamic> responseData = json.decode(response.body);
        final List<dynamic> crimes = responseData['data'] ?? [];

        Map<String, int> counts = {};

        setState(() {
          crimeMarkers = crimes.map((c) {
            final l = double.parse(c['lat'].toString());
            final ln = double.parse(c['lon'].toString());
            String tipo = (c['tipo'] ?? 'N/I').toString().toUpperCase();
            counts[tipo] = (counts[tipo] ?? 0) + 1;

            // CORES REFINADAS (ACIDENTES VS OUTROS)
            Color corPonto;

            if (menuIndex == 2) { 
              // ESTAMOS NA ABA ACIDENTES
              // Vamos pintar de ROXO se for LEVE, para provar que é diferente de Celular
              String sev = c['severidade'] ?? 'N/A';
              
              if (sev == 'FATAL') corPonto = Colors.red;
              else if (sev == 'GRAVE') corPonto = Colors.orange;
              else corPonto = Colors.purpleAccent; // <--- MUDANÇA AQUI: LEVE vira ROXO
              
              // Print de Debug no Console do Flutter (veja no terminal "Run")
              print("ACIDENTE ENCONTRADO: Lat: $l, Lon: $ln, Sev: $sev");

            } else {
              // Celulares e Veículos continuam Amarelos/Vermelhos por quantidade
              corPonto = (c['quantidade'] ?? 1) > 10 ? Colors.red : Colors.yellow;
            }

            return Marker(
              point: LatLng(l, ln),
              width: 26,
              height: 26,
              child: GestureDetector(
                onTap: () => buscarDetalhesPonto(l, ln),
                child: Container(
                  decoration: BoxDecoration(
                      color: corPonto,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black, width: 2)),
                  child: Center(
                      child: Text("${c['quantidade'] ?? 1}",
                          style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: Colors.black))),
                ),
              ),
            );
          }).toList();
          estatisticasMarcas = counts;
        });
      }
    } catch (e) {
      _snack("Erro de conexão com o backend.");
    } finally {
      setState(() => carregando = false);
    }
  }

  // --- 3. FERRAMENTAS AUXILIARES ---
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
    Color themeColor = menuIndex == 0
        ? Colors.cyan
        : (menuIndex == 1 ? Colors.greenAccent : Colors.orangeAccent);

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
          BottomNavigationBarItem(
              icon: Icon(Icons.warning_amber), label: "Acidentes"),
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
    var sort = estatisticasMarcas.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Container(
      width: 200,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.amber.withOpacity(0.5))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(menuIndex == 2 ? "TOP TIPOS ACIDENTE" : "TOP MARCAS/MODELOS",
            style: const TextStyle(
                color: Colors.amber,
                fontSize: 10,
                fontWeight: FontWeight.bold)),
        const Divider(color: Colors.amber, height: 15),
        ...sort.take(5).map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                        child: Text(e.key,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10))),
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
