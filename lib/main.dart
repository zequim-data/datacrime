import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:convert';

// --- ESTILO DARK MODE DO MAPA (JSON) ---
const String _darkMapStyle = '''
[
  {
    "elementType": "geometry",
    "stylers": [{"color": "#212121"}]
  },
  {
    "elementType": "labels.icon",
    "stylers": [{"visibility": "off"}]
  },
  {
    "elementType": "labels.text.fill",
    "stylers": [{"color": "#757575"}]
  },
  {
    "elementType": "labels.text.stroke",
    "stylers": [{"color": "#212121"}]
  },
  {
    "featureType": "administrative",
    "elementType": "geometry",
    "stylers": [{"color": "#757575"}]
  },
  {
    "featureType": "poi",
    "elementType": "geometry",
    "stylers": [{"color": "#eeeeee"}]
  },
  {
    "featureType": "poi",
    "elementType": "labels.text.fill",
    "stylers": [{"color": "#757575"}]
  },
  {
    "featureType": "road",
    "elementType": "geometry",
    "stylers": [{"color": "#2c2c2c"}]
  },
  {
    "featureType": "road.arterial",
    "elementType": "labels.text.fill",
    "stylers": [{"color": "#757575"}]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry",
    "stylers": [{"color": "#3c3c3c"}]
  },
  {
    "featureType": "water",
    "elementType": "geometry",
    "stylers": [{"color": "#000000"}]
  }
]
''';

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
  final Completer<GoogleMapController> _controller = Completer();
  final TextEditingController _searchController = TextEditingController();

  // --- ESTADOS DO APP ---
  Set<Marker> _markers = {};
  LatLng? pontoSelecionado;

  double raioBusca = 300.0;
  String filtroAno = "2025";
  int menuIndex = 0; // 0=Celular, 1=Veículo, 2=Acidente

  Map<String, int> estatisticasMarcas = {};
  bool carregando = false;

  // URL DA SUA API NO CLOUD RUN
  final String baseUrl =
      "https://zecchin-api-997663776889.southamerica-east1.run.app";

  String get tipoCrimeParam {
    if (menuIndex == 0) return "celular";
    if (menuIndex == 1) return "veiculo";
    return "acidente";
  }

  // --- 1. GERADOR DE BOLINHAS (TEXTO -> IMAGEM BITMAP) ---
// --- 1. GERADOR DE BOLINHAS (TEXTO -> IMAGEM BITMAP) ---
  Future<BitmapDescriptor> _criarIconeCustomizado(String texto, Color cor) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = cor.withOpacity(0.9);
    
    // --- MUDANÇA AQUI: Reduzi de 110 para 60 ---
    final int size = 60; 
    // ------------------------------------------

    // Desenha o Círculo Colorido
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint);
    
    // Desenha Borda Branca
    Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3; // Dei uma afinada na borda também (de 4 pra 3)
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, borderPaint);

    // Desenha o Texto (Número)
    TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: texto,
      // Ajustei o tamanho da fonte proporcionalmente
      style: TextStyle(fontSize: size / 2.2, color: Colors.white, fontWeight: FontWeight.bold),
    );
    painter.layout();
    painter.paint(canvas, Offset((size - painter.width) / 2, (size - painter.height) / 2));

    final ui.Image img = await pictureRecorder.endRecording().toImage(size, size);
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  // --- 2. BUSCAR DADOS RESUMIDOS (BOLINHAS) ---
  Future<void> buscarCrimes(LatLng pos) async {
    setState(() {
      pontoSelecionado = pos;
      carregando = true;
    });

    try {
      final url = Uri.parse(
          '$baseUrl/crimes?lat=${pos.latitude}&lon=${pos.longitude}&raio=${raioBusca.toInt()}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        final List<dynamic> crimes = responseData['data'] ?? [];

        Map<String, int> counts = {};
        Set<Marker> newMarkers = {};

        for (var c in crimes) {
          final l = double.parse(c['lat'].toString());
          final ln = double.parse(c['lon'].toString());

          // Contagem para o ranking
       String tipo = (c['tipo'] ?? 'N/I').toString().toUpperCase();
            counts[tipo] = (counts[tipo] ?? 0) + 1;

            // --- MUDANÇA AQUI: Lógica unificada para mostrar NÚMEROS sempre ---
            Color corMarker = Colors.yellow;
            int qtd = c['quantidade'] ?? 1; // Pega a quantidade ou assume 1
            String textoLabel = "$qtd";     // Sempre mostra o número

            if (menuIndex == 2) { // Acidente
              String sev = c['severidade'] ?? 'LEVE';
              // Removemos o textoLabel = "!" e mantemos o número
              if (sev == 'FATAL') corMarker = Colors.red;
              else if (sev == 'GRAVE') corMarker = Colors.orange;
              else corMarker = Colors.purpleAccent; 
            } else { // Crimes
              if (qtd > 10) corMarker = Colors.red;
              else if (qtd > 5) corMarker = Colors.orange;
            }
            // -----------------------------------------------------------------

            // Gera o ícone
            BitmapDescriptor icon = await _criarIconeCustomizado(textoLabel, corMarker);
          newMarkers.add(Marker(
            markerId: MarkerId("${c['lat']}_${c['lon']}"),
            position: LatLng(l, ln),
            icon: icon,
            onTap: () => buscarDetalhesPonto(LatLng(l, ln)),
          ));
        }

        setState(() {
          _markers = newMarkers;
          estatisticasMarcas = counts;
        });
      }
    } catch (e) {
      print("Erro ao buscar crimes: $e");
      _snack("Erro de conexão com o servidor.");
    } finally {
      setState(() => carregando = false);
    }
  }

  // --- 3. BUSCAR DETALHES (GAVETA) ---
  Future<void> buscarDetalhesPonto(LatLng pos) async {
    setState(() => carregando = true);
    final url = Uri.parse(
        '$baseUrl/detalhes?lat=${pos.latitude}&lon=${pos.longitude}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        // Decodifica UTF-8 para aceitar acentos
        String body = utf8.decode(response.bodyBytes);
        final Map<String, dynamic> responseData = json.decode(body);
        _exibirGavetaDetalhes(responseData['data'] ?? []);
      } else {
        _snack("Erro no servidor: ${response.statusCode}");
      }
    } catch (e) {
      _snack("Erro ao buscar detalhes.");
    } finally {
      setState(() => carregando = false);
    }
  }

  // --- 4. EXIBIR A GAVETA (UI) ---
  void _exibirGavetaDetalhes(List<dynamic> lista) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.95),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (_, scroll) => Container(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            // Puxador da gaveta
            Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10))),
            const SizedBox(height: 15),

            Text("${lista.length} REGISTROS NESTE LOCAL",
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
                bool isAcidente = menuIndex == 2;

                // Cor do Título baseada na gravidade
                Color corTitulo = Colors.cyan;
                String severidade = "";
                if (isAcidente) {
                  severidade = c['severidade'] ?? 'LEVE';
                  if (severidade == 'FATAL')
                    corTitulo = Colors.redAccent;
                  else if (severidade == 'GRAVE')
                    corTitulo = Colors.orangeAccent;
                  else
                    corTitulo = Colors.purpleAccent;
                }

                return Card(
                  color: Colors.white.withOpacity(0.05),
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  child: ExpansionTile(
                    iconColor: corTitulo,
                    collapsedIconColor: Colors.white54,
                    title: Text("${c['rubrica'] ?? 'OCORRÊNCIA'}",
                        style: TextStyle(
                            color: corTitulo,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    subtitle: Row(
                      children: [
                        Text("${c['data'] ?? 'DATA N/I'}",
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                        if (isAcidente) ...[
                          const SizedBox(width: 10),
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: corTitulo.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: corTitulo.withOpacity(0.5))),
                              child: Text(severidade,
                                  style: TextStyle(
                                      color: corTitulo,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)))
                        ]
                      ],
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(15),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isAcidente) ...[
                                // Ícones de Estatística
                                Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    children: [
                                      _iconStat(Icons.directions_car,
                                          c['autos'], "Carros"),
                                      _iconStat(Icons.two_wheeler, c['motos'],
                                          "Motos"),
                                      _iconStat(Icons.directions_walk,
                                          c['pedestres'], "Pedestres"),
                                    ]),
                                const SizedBox(height: 15),
                                // Lista de Veículos
                                if (c['lista_veiculos'] != null &&
                                    (c['lista_veiculos'] as List)
                                        .isNotEmpty) ...[
                                  const Text("VEÍCULOS:",
                                      style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 5),
                                  ...(c['lista_veiculos'] as List)
                                      .map((v) => _cardVeiculo(v))
                                      .toList(),
                                  const SizedBox(height: 15),
                                ],
                                // Lista de Vítimas
                                if (c['lista_pessoas'] != null &&
                                    (c['lista_pessoas'] as List)
                                        .isNotEmpty) ...[
                                  const Text("VÍTIMAS / ENVOLVIDOS:",
                                      style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 10,
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
                                // Detalhes SSP (Celular/Veículo)
                                _itemInfo("Marca/Objeto:", c['marca']),
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
            )),
          ]),
        ),
      ),
    );
  }

  // --- WIDGETS AUXILIARES DA GAVETA ---
  Widget _cardVeiculo(dynamic v) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(5),
          border: Border(
              left: BorderSide(color: Colors.cyan.withOpacity(0.5), width: 3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("${v['modelo'] ?? 'Modelo N/I'}  (${v['ano_fab'] ?? '-'})",
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
        const SizedBox(height: 2),
        Text("Cor: ${v['cor'] ?? '-'} • Tipo: ${v['tipo'] ?? '-'}",
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }

  Widget _cardPessoa(dynamic p) {
    Color corLesao = Colors.grey;
    String lesao = (p['lesao'] ?? '').toString().toUpperCase();
    if (lesao.contains("FATAL") || lesao.contains("MORTO"))
      corLesao = Colors.red;
    else if (lesao.contains("GRAVE"))
      corLesao = Colors.orange;
    else if (lesao.contains("LEVE")) corLesao = Colors.yellow;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(5),
          border: Border(
              left: BorderSide(color: corLesao.withOpacity(0.8), width: 3))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.person, size: 16, color: corLesao),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  "${p['tipo_vitima'] ?? 'VÍTIMA'} • ${p['sexo'] ?? '?'} • ${p['idade'] != null ? '${p['idade']} anos' : '-'}",
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12)),
              const SizedBox(height: 2),
              Text("Lesão: ${p['lesao'] ?? 'N/I'} • ${p['profissao'] ?? '-'}",
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
          )
        ],
      ),
    );
  }

  Widget _iconStat(IconData icon, dynamic count, String label) {
    int val = 0;
    if (count is int)
      val = count;
    else if (count is double) val = count.toInt();
    Color color = val > 0 ? Colors.white : Colors.white24;
    return Column(children: [
      Icon(icon, color: color, size: 24),
      Text(val.toString(),
          style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      Text(label, style: TextStyle(color: color.withOpacity(0.5), fontSize: 9)),
    ]);
  }

  Widget _itemInfo(String label, String? v) {
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("$label ",
            style: const TextStyle(
                color: Colors.amber,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
        Expanded(
            child: Text(v,
                style: const TextStyle(color: Colors.white, fontSize: 12))),
      ]),
    );
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

  // --- CONSTRUÇÃO DA TELA (BUILD) ---
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
        unselectedItemColor: Colors.white70, // AQUI: Ficou mais visível!
        onTap: (i) {
          setState(() {
            menuIndex = i;
            _markers = {};
            estatisticasMarcas = {};
            pontoSelecionado = null;
          });
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
        // CAMADA 1: O MAPA
        GoogleMap(
          mapType: MapType.normal,
          initialCameraPosition: const CameraPosition(
            target: LatLng(-23.5505, -46.6333),
            zoom: 14.4746,
          ),
          onMapCreated: (GoogleMapController controller) {
            _controller.complete(controller);
            // Aplica o tema Dark
            controller.setMapStyle(_darkMapStyle);
          },
          markers: _markers,
          myLocationEnabled: true,
          myLocationButtonEnabled: false, // Usamos nosso botão custom
          zoomControlsEnabled: false, // Mapa limpo
          onTap: (pos) => buscarCrimes(pos), // Clicou no mapa, busca!
        ),

        // CAMADA 2: BARRA DE BUSCA (Topo)
        Positioned(
            top: 50,
            left: 15,
            right: 15,
            child: Container(
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: Colors.amber.withOpacity(0.5))),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    hintText: "Toque no mapa para buscar...",
                    hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                    prefixIcon: Icon(Icons.search, color: Colors.amber),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 15)),
              ),
            )),

        // CAMADA 3: CONTROLES DE RAIO E ANO
        Positioned(
            top: 120,
            left: 15,
            right: 15,
            child: Column(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: themeColor.withOpacity(0.5))),
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
                      onChanged: (v) => setState(() => raioBusca = v),
                      onChangeEnd: (v) {
                        if (pontoSelecionado != null)
                          buscarCrimes(pontoSelecionado!);
                      }),
                ]),
              ),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _btn("2025", "2025"),
                _btn("3 ANOS", "3_anos"),
                _btn("5 ANOS", "5_anos")
              ]),
            ])),

        // CAMADA 4: BOTÃO GPS
        Positioned(
            bottom: 20,
            left: 15,
            child: FloatingActionButton(
                backgroundColor: themeColor,
                onPressed: _gps,
                child: const Icon(Icons.my_location, color: Colors.black))),

        // CAMADA 5: LISTINHA DE ESTATÍSTICAS (Onde estava o erro de sintaxe)
        if (estatisticasMarcas.isNotEmpty)
          Positioned(
              bottom: 20,
              right: 15,
              child: Container(
                  width: 200,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: Colors.amber.withOpacity(0.5))),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(menuIndex == 2 ? "TOP TIPOS" : "TOP MARCAS",
                        style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                    const Divider(color: Colors.amber, height: 15),

                    // --- CORREÇÃO DA SINTAXE AQUI ---
                    ...(estatisticasMarcas.entries.toList()
                          ..sort((a, b) => b.value.compareTo(
                              a.value))) // Parênteses resolvem a ordem
                        .take(5)
                        .map((e) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                      child: Text(e.key,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 10))),
                                  Text("${e.value}",
                                      style: TextStyle(
                                          color: themeColor,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10))
                                ])))
                        .toList(),
                    // --------------------------------
                  ]))),

        if (carregando)
          const Center(
              child: CircularProgressIndicator(
                  color: Colors.amber, strokeWidth: 8)),
      ]),
    );
  }

  Widget _btn(String l, String v) {
    bool s = filtroAno == v;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: s ? Colors.amber : Colors.grey[900]),
            onPressed: () {
              setState(() => filtroAno = v);
              if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!);
            },
            child: Text(l,
                style: TextStyle(
                    color: s ? Colors.black : Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold))));
  }
}
