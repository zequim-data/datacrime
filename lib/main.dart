import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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
  final Completer<GoogleMapController> _controller = Completer();
  final TextEditingController _searchController = TextEditingController();

  // --- ESTADOS DO APP ---
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  LatLng? pontoSelecionado;
  
  double raioBusca = 300.0;
  String filtroAno = "2025";
  int menuIndex = 0; // 0=Celular, 1=Veículo, 2=Acidente
  
  Map<String, int> estatisticasMarcas = {};
  bool carregando = false;

  final String baseUrl = "https://zecchin-api-997663776889.southamerica-east1.run.app";

  String get tipoCrimeParam {
    if (menuIndex == 0) return "celular";
    if (menuIndex == 1) return "veiculo";
    return "acidente";
  }

  // Cores Dinâmicas (O que você gostou!)
  Color get themeColor {
    if (menuIndex == 0) return Colors.cyanAccent; // Celular
    if (menuIndex == 1) return Colors.greenAccent; // Veículo
    return Colors.orangeAccent; // Acidente
  }

  void _atualizarCirculo() {
    if (pontoSelecionado == null) return;
    setState(() {
      _circles = {
        Circle(
          circleId: const CircleId("raio_analise"),
          center: pontoSelecionado!,
          radius: raioBusca,
          fillColor: themeColor.withOpacity(0.15), // Cor do tema bem suave
          strokeColor: themeColor,
          strokeWidth: 2,
        )
      };
    });
  }

  // --- 1. GERADOR DE BOLINHAS (AGORA PEQUENAS: 40px) ---
  Future<BitmapDescriptor> _criarIconeCustomizado(String texto, Color cor) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = cor.withOpacity(0.9);
    
    // TAMANHO REDUZIDO
    final int size = 40; 

    // Círculo Fundo
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint);
    
    // Borda
    Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2; 
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, borderPaint);

    // Texto
    TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: texto,
      style: TextStyle(fontSize: 13, color: Colors.black, fontWeight: FontWeight.bold), // Fonte preta pra ler melhor no colorido
    );
    painter.layout();
    painter.paint(canvas, Offset((size - painter.width) / 2, (size - painter.height) / 2));

    final ui.Image img = await pictureRecorder.endRecording().toImage(size, size);
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  // --- 2. BUSCAR DADOS ---
  Future<void> buscarCrimes(LatLng pos) async {
    setState(() {
      pontoSelecionado = pos;
      carregando = true;
      _atualizarCirculo();
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
            
            String tipo = (c['tipo'] ?? 'N/I').toString().toUpperCase();
            counts[tipo] = (counts[tipo] ?? 0) + 1;

            Color corMarker = themeColor; 
            int qtd = c['quantidade'] ?? 1;
            String textoLabel = "$qtd"; 

            if (menuIndex == 2) { // Acidente
              String sev = c['severidade'] ?? 'LEVE';
              if (sev == 'FATAL') corMarker = Colors.red;
              else if (sev == 'GRAVE') corMarker = Colors.orange;
              else corMarker = Colors.yellow; 
            } else { // Crimes
               if (qtd > 10) corMarker = Colors.red;
               else if (qtd > 5) corMarker = Colors.orange;
            }

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
      _snack("Erro de conexão.");
    } finally {
      setState(() => carregando = false);
    }
  }

  // --- 3. BUSCAR DETALHES ---
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
      }
    } catch (e) {
      _snack("Erro ao buscar detalhes.");
    } finally {
      setState(() => carregando = false);
    }
  }

  // --- 4. GAVETA (UI DARK HACKER) ---
  void _exibirGavetaDetalhes(List<dynamic> lista) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.9), // Fundo Preto Hacker
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
            Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10))),
            const SizedBox(height: 15),
            
            Text("${lista.length} REGISTROS ENCONTRADOS", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 16)),
            Divider(color: themeColor, height: 25),

            Expanded(
                child: ListView.builder(
              controller: scroll,
              itemCount: lista.length,
              itemBuilder: (context, i) {
                final c = lista[i];
                bool isAcidente = menuIndex == 2; 
                return Card(
                  color: Colors.white.withOpacity(0.08), // Card semitransparente
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  child: ExpansionTile(
                    iconColor: themeColor,
                    collapsedIconColor: Colors.white54,
                    title: Text("${c['rubrica'] ?? 'OCORRÊNCIA'}", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: Text("${c['data'] ?? ''}", style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(15),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (isAcidente) ...[
                             Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                                 _iconStat(Icons.directions_car, c['autos'], "Carros"),
                                 _iconStat(Icons.two_wheeler, c['motos'], "Motos"),
                                 _iconStat(Icons.directions_walk, c['pedestres'], "Pedestres"),
                             ]),
                             const SizedBox(height: 10),
                             _itemInfo("Severidade:", c['severidade']),
                             _itemInfo("Local:", c['local_texto']),
                          ] else ...[
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
            )),
          ]),
        ),
      ),
    );
  }

  Widget _iconStat(IconData icon, dynamic count, String label) {
    int val = 0;
    if (count is int) val = count;
    else if (count is double) val = count.toInt();
    Color color = val > 0 ? Colors.white : Colors.white24;
    return Column(children: [
        Icon(icon, color: color, size: 24),
        Text(val.toString(), style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(color: color.withOpacity(0.5), fontSize: 9)),
    ]);
  }

  Widget _itemInfo(String label, String? v) {
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("$label ", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 12)),
        Expanded(child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 12))),
      ]),
    );
  }

  Future<void> _gps() async {
    LocationPermission p = await Geolocator.requestPermission();
    if (p != LocationPermission.denied) {
      Position pos = await Geolocator.getCurrentPosition();
      final GoogleMapController controller = await _controller.future;
      controller.animateCamera(CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 15));
      buscarCrimes(LatLng(pos.latitude, pos.longitude));
    }
  }

  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t), backgroundColor: Colors.red));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // Fundo do App Branco (Mapa Claro)
      
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: menuIndex,
        backgroundColor: Colors.black, // BARRA PRETA
        selectedItemColor: themeColor, // Cores Vivas
        unselectedItemColor: Colors.white30,
        type: BottomNavigationBarType.fixed, // Fixa para não pular
        onTap: (i) {
          setState(() { 
            menuIndex = i; 
            _markers = {}; 
            _circles = {};
            estatisticasMarcas = {};
            pontoSelecionado = null;
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.phone_android), label: "Celulares"),
          BottomNavigationBarItem(icon: Icon(Icons.directions_car), label: "Veículos"),
          BottomNavigationBarItem(icon: Icon(Icons.warning_amber), label: "Acidentes"),
        ],
      ),

      body: Stack(children: [
        
        // CAMADA 1: O MAPA CLARO (Padrão)
        GoogleMap(
          mapType: MapType.normal,
          initialCameraPosition: const CameraPosition(
            target: LatLng(-23.5505, -46.6333),
            zoom: 14.4746,
          ),
          onMapCreated: (GoogleMapController controller) {
            _controller.complete(controller);
          },
          markers: _markers,
          circles: _circles,
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
          onTap: (pos) => buscarCrimes(pos),
        ),
        
        // CAMADA 2: BARRA DE BUSCA (Preta/Transparente)
        Positioned(
          top: 50, left: 15, right: 15,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.85), // Fundo Hacker
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: themeColor.withOpacity(0.5)), // Borda Colorida
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)]
            ),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                  hintText: "Toque no mapa para buscar...",
                  hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                  prefixIcon: Icon(Icons.search, color: themeColor),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 15)),
            ),
          )
        ),

        // CAMADA 3: CONTROLES (Slider + Anos)
        Positioned(
          top: 120, left: 15, right: 15,
          // GestureDetector impede que arrastar o slider mova o mapa
          child: GestureDetector(
            onVerticalDragUpdate: (_) {}, 
            child: Column(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85), 
                  borderRadius: BorderRadius.circular(15), 
                  border: Border.all(color: themeColor.withOpacity(0.5))
                ),
                child: Column(children: [
                  Text("RAIO: ${raioBusca.toInt()} METROS", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 11)),
                  Slider(
                    value: raioBusca, 
                    min: 10, max: 1000, divisions: 99, 
                    activeColor: themeColor, 
                    inactiveColor: Colors.grey[800],
                    onChanged: (v) => setState(() { 
                      raioBusca = v; 
                      _atualizarCirculo(); 
                    }), 
                    onChangeEnd: (v) { if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!); }
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [_btn("2025", "2025"), _btn("3 ANOS", "3_anos"), _btn("5 ANOS", "5_anos")]),
            ]),
          )
        ),

        // CAMADA 4: BOTÃO GPS
        Positioned(
          bottom: 20, left: 15, 
          child: FloatingActionButton(backgroundColor: themeColor, onPressed: _gps, child: const Icon(Icons.my_location, color: Colors.black))
        ),

        // CAMADA 5: LISTINHA DE ESTATÍSTICAS
        if (estatisticasMarcas.isNotEmpty)
          Positioned(
            bottom: 20, right: 15, 
            child: Container(
              width: 200, padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.9), 
                borderRadius: BorderRadius.circular(15), 
                border: Border.all(color: themeColor.withOpacity(0.5))
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min, 
                children: [
                  Text(menuIndex == 2 ? "TOP TIPOS" : "TOP MARCAS", style: TextStyle(color: themeColor, fontSize: 10, fontWeight: FontWeight.bold)),
                  Divider(color: themeColor, height: 15),
                  
                  ... (estatisticasMarcas.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                     .take(5)
                     .map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Flexible(child: Text(e.key, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 10))), Text("${e.value}", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 10))]))).toList(),
                ]
              )
            )
          ),
          
        if (carregando)
          Center(child: CircularProgressIndicator(color: themeColor, strokeWidth: 8)),
      ]),
    );
  }

  Widget _btn(String l, String v) {
    bool s = filtroAno == v;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ElevatedButton(style: ElevatedButton.styleFrom(
      backgroundColor: s ? themeColor : Colors.black.withOpacity(0.8),
      foregroundColor: s ? Colors.black : Colors.white,
      side: BorderSide(color: s ? Colors.transparent : themeColor.withOpacity(0.5))
    ), onPressed: () { setState(() => filtroAno = v); if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!); }, child: Text(l, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold))));
  }
}