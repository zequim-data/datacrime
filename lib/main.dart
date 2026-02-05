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

  // --- ATENÇÃO: VERIFIQUE SE A 'GEOCODING API' ESTÁ ATIVA NO GOOGLE CLOUD ---
  final String googleApiKey = "AIzaSyDj2xClrlZVaLGs1H-m6XPNsLEhMbZ64Vw"; 
  final String baseUrl = "https://zecchin-api-997663776889.southamerica-east1.run.app";

  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  LatLng? pontoSelecionado;
  
  double raioBusca = 300.0;
  String filtroAno = "2025";
  int menuIndex = 0; 
  
  Map<String, int> estatisticasMarcas = {};
  bool carregando = false;

  String get tipoCrimeParam {
    if (menuIndex == 0) return "celular";
    if (menuIndex == 1) return "veiculo";
    return "acidente";
  }

  // --- 1. COR MAIS VIVA (LARANJA NEON) ---
  Color get themeColor => Colors.orangeAccent; 

  // --- BUSCA DE ENDEREÇO ---
  Future<void> _buscarPorTexto(String endereco) async {
    if (endereco.isEmpty) return;
    setState(() => carregando = true);
    
    final url = Uri.parse("https://maps.googleapis.com/maps/api/geocode/json?address=$endereco&key=$googleApiKey");

    try {
      final response = await http.get(url);
      final data = json.decode(response.body);

      if (data['status'] == 'OK') {
        final location = data['results'][0]['geometry']['location'];
        final destino = LatLng(location['lat'], location['lng']);

        final GoogleMapController controller = await _controller.future;
        controller.animateCamera(CameraUpdate.newLatLngZoom(destino, 16));
        buscarCrimes(destino);
      } else {
        // Mostra o erro real do Google (ex: REQUEST_DENIED)
        _snack("Erro Google: ${data['status']} - Verifique se a Geocoding API está ativada.");
      }
    } catch (e) {
      _snack("Erro na busca: $e");
    } finally {
      setState(() => carregando = false);
    }
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

  // --- GERADOR DE MARCADOR (BOLINHA) ---
  Future<BitmapDescriptor> _criarIconeCustomizado(String texto, Color cor) async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = cor.withOpacity(1.0); // Opacidade total para cor viva
    final int size = 28; // Tamanho levemente ajustado

    // Fundo
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, paint);
    
    // Borda
    Paint borderPaint = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.0; 
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2.0, borderPaint);

    // Texto (Só mostra se > 1 para limpar visual, ou se for cluster)
    if (int.tryParse(texto) != null && int.parse(texto) > 1) {
      TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
      painter.text = TextSpan(text: texto, style: const TextStyle(fontSize: 11, color: Colors.black, fontWeight: FontWeight.bold));
      painter.layout();
      painter.paint(canvas, Offset((size - painter.width) / 2, (size - painter.height) / 2));
    }

    final ui.Image img = await pictureRecorder.endRecording().toImage(size, size);
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  // --- 2. BUSCA COM AGRUPAMENTO (CLUSTERING) ---
  Future<void> buscarCrimes(LatLng pos) async {
    setState(() {
      pontoSelecionado = pos;
      carregando = true;
      _atualizarCirculo();
    });

    try {
      final url = Uri.parse('$baseUrl/crimes?lat=${pos.latitude}&lon=${pos.longitude}&raio=${raioBusca.toInt()}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        final List<dynamic> crimes = responseData['data'] ?? [];
        
        if (crimes.isEmpty) _snack("Nenhum registro encontrado.");

        Map<String, int> counts = {};
        
        // --- LOGICA DE AGRUPAMENTO (CLUSTERING) ---
        Map<String, int> clusterCount = {}; // Chave: "lat_lon", Valor: Total
        Map<String, dynamic> clusterData = {}; // Guarda um exemplar para pegar tipo/severidade

        for (var c in crimes) {
            String latLonKey = "${c['lat']}_${c['lon']}";
            int qtd = c['quantidade'] ?? 1;
            
            // Soma no cluster
            clusterCount[latLonKey] = (clusterCount[latLonKey] ?? 0) + qtd;
            clusterData[latLonKey] = c; // Guarda referência

            // Estatística Global
            String tipo = (c['tipo'] ?? 'N/I').toString().toUpperCase();
            counts[tipo] = (counts[tipo] ?? 0) + 1;
        }

        Set<Marker> newMarkers = {};

        // Agora criamos marcadores baseados nos CLUSTERS, não na lista bruta
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

            // O ícone agora exibe o TOTAL naquele ponto
            BitmapDescriptor icon = await _criarIconeCustomizado("$totalCluster", corMarker);

            newMarkers.add(Marker(
              markerId: MarkerId(key),
              position: LatLng(l, ln),
              icon: icon,
              // Ao clicar, busca detalhes daquela coordenada (o backend já traz tudo dali)
              onTap: () => buscarDetalhesPonto(LatLng(l, ln)),
            ));
        }
        // -------------------------------------------

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

  Future<void> buscarDetalhesPonto(LatLng pos) async {
    setState(() => carregando = true);
    final url = Uri.parse('$baseUrl/detalhes?lat=${pos.latitude}&lon=${pos.longitude}&filtro=$filtroAno&tipo_crime=$tipoCrimeParam');

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

  void _exibirGavetaDetalhes(List<dynamic> lista) {
    showModalBottomSheet(
      context: context, backgroundColor: Colors.black.withOpacity(0.9), isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(25))),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6, maxChildSize: 0.95, minChildSize: 0.4, expand: false,
        builder: (_, scroll) => Container(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10))),
            const SizedBox(height: 15),
            Text("${lista.length} REGISTROS AQUI", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 16)),
            Divider(color: themeColor, height: 25),
            Expanded(child: ListView.builder(
              controller: scroll, itemCount: lista.length,
              itemBuilder: (context, i) {
                final c = lista[i];
                bool isAcidente = menuIndex == 2; 
                return Card(
                  color: Colors.white.withOpacity(0.1), margin: const EdgeInsets.symmetric(vertical: 8),
                  child: ExpansionTile(
                    iconColor: themeColor, collapsedIconColor: Colors.white70,
                    title: Text("${c['rubrica'] ?? 'OCORRÊNCIA'}", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Text("${c['data'] ?? ''}", style: const TextStyle(color: Colors.white60, fontSize: 11)),
                    children: [
                      Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (isAcidente) ...[
                             Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                                 _iconStat(Icons.directions_car, c['autos'], "Carros"),
                                 _iconStat(Icons.two_wheeler, c['motos'], "Motos"),
                                 _iconStat(Icons.directions_walk, c['pedestres'], "Pedestres"),
                             ]),
                             const SizedBox(height: 15),
                             if (c['lista_veiculos'] != null && (c['lista_veiculos'] as List).isNotEmpty) ...[
                               Text("VEÍCULOS:", style: TextStyle(color: themeColor, fontSize: 11, fontWeight: FontWeight.bold)),
                               const SizedBox(height: 5),
                               ... (c['lista_veiculos'] as List).map((v) => _cardVeiculo(v)).toList(),
                               const SizedBox(height: 15),
                             ],
                             if (c['lista_pessoas'] != null && (c['lista_pessoas'] as List).isNotEmpty) ...[
                               Text("VÍTIMAS:", style: TextStyle(color: themeColor, fontSize: 11, fontWeight: FontWeight.bold)),
                               const SizedBox(height: 5),
                               ... (c['lista_pessoas'] as List).map((p) => _cardPessoa(p)).toList(),
                             ],
                             const Divider(color: Colors.white24, height: 20),
                             _itemInfo("Local:", c['local_texto']),
                          ] else ...[
                              _itemInfo("Marca:", c['marca']),
                              if (menuIndex == 1) ...[ _itemInfo("Placa:", c['placa']), _itemInfo("Cor:", c['cor']), ],
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

  Widget _cardVeiculo(dynamic v) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(5), border: Border(left: BorderSide(color: themeColor, width: 2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("${v['modelo'] ?? 'Modelo N/I'}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
        Text("Cor: ${v['cor'] ?? '-'} • Tipo: ${v['tipo'] ?? '-'}", style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ]),
    );
  }

  Widget _cardPessoa(dynamic p) {
    Color cor = Colors.blue;
    String l = (p['lesao'] ?? '').toString().toUpperCase();
    if (l.contains("FATAL") || l.contains("MORTO")) cor = Colors.red;
    return Container(
      margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(5), border: Border(left: BorderSide(color: cor, width: 2))),
      child: Text("${p['tipo_vitima']} • ${p['sexo']} • ${p['idade'] ?? '-'} anos\n${p['lesao']}", style: const TextStyle(color: Colors.white, fontSize: 11)),
    );
  }

  Widget _iconStat(IconData icon, dynamic count, String label) {
    int val = 0;
    if (count is int) val = count; else if (count is double) val = count.toInt();
    return Column(children: [Icon(icon, color: Colors.white, size: 20), Text(val.toString(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)), Text(label, style: const TextStyle(color: Colors.white54, fontSize: 9))]);
  }

  Widget _itemInfo(String label, String? v) {
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Text("$label ", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 12)), Expanded(child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 12)))]));
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
      backgroundColor: Colors.white,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: menuIndex, backgroundColor: Colors.black, selectedItemColor: themeColor, unselectedItemColor: Colors.white30, type: BottomNavigationBarType.fixed,
        onTap: (i) {
           setState(() { 
             menuIndex = i; 
             _markers = {}; 
             if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!);
           }); 
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.phone_android), label: "Celulares"),
          BottomNavigationBarItem(icon: Icon(Icons.directions_car), label: "Veículos"),
          BottomNavigationBarItem(icon: Icon(Icons.warning_amber), label: "Acidentes"),
        ],
      ),
      body: Stack(children: [
        GoogleMap(
          mapType: MapType.normal, initialCameraPosition: const CameraPosition(target: LatLng(-23.5505, -46.6333), zoom: 14.4746),
          onMapCreated: (c) { _controller.complete(c); }, markers: _markers, circles: _circles, myLocationEnabled: true, myLocationButtonEnabled: false, zoomControlsEnabled: false, onTap: buscarCrimes,
        ),
        
        // --- 3. PROTEÇÃO DE CLIQUE NO INPUT ---
        Positioned(top: 50, left: 15, right: 15, child: GestureDetector(
            onTap: (){}, // Bloqueia toque
            child: Container(
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.85), borderRadius: BorderRadius.circular(30), border: Border.all(color: themeColor.withOpacity(0.5))),
              child: TextField(
                controller: _searchController, 
                onSubmitted: _buscarPorTexto, 
                textInputAction: TextInputAction.search, 
                style: const TextStyle(color: Colors.white), 
                decoration: InputDecoration(hintText: "Digite endereço ou CEP...", hintStyle: const TextStyle(color: Colors.white38, fontSize: 13), prefixIcon: Icon(Icons.search, color: themeColor), border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 15))
              ),
        ))),

        // --- 3. PROTEÇÃO DE CLIQUE NO SLIDER (HitTestBehavior) ---
        Positioned(top: 120, left: 15, right: 15, child: GestureDetector(
            onTap: () {}, // Consome cliques simples
            behavior: HitTestBehavior.opaque, // Garante que o toque não passa pro mapa
            child: Column(children: [
              Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.black.withOpacity(0.85), borderRadius: BorderRadius.circular(15), border: Border.all(color: themeColor.withOpacity(0.5))),
                child: Column(children: [Text("RAIO: ${raioBusca.toInt()} METROS", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 11)), Slider(value: raioBusca, min: 10, max: 1000, divisions: 99, activeColor: themeColor, inactiveColor: Colors.grey[800], onChanged: (v) => setState(() { raioBusca = v; _atualizarCirculo(); }), onChangeEnd: (v) { if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!); })]),
              ),
              const SizedBox(height: 10),
              // Botões de Ano
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [_btn("2025", "2025"), _btn("3 ANOS", "3_anos"), _btn("5 ANOS", "5_anos")]),
            ]),
        )),

        Positioned(bottom: 20, left: 15, child: FloatingActionButton(backgroundColor: themeColor, onPressed: _gps, child: const Icon(Icons.my_location, color: Colors.black))),
        
        // Estatísticas
        if (estatisticasMarcas.isNotEmpty) Positioned(bottom: 20, right: 15, child: GestureDetector(
          onTap: (){}, // Protege clique na lista
          child: Container(width: 200, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), borderRadius: BorderRadius.circular(15), border: Border.all(color: themeColor.withOpacity(0.5))), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(menuIndex == 2 ? "TOP TIPOS" : "TOP MARCAS", style: TextStyle(color: themeColor, fontSize: 10, fontWeight: FontWeight.bold)), Divider(color: themeColor, height: 15), ... (estatisticasMarcas.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(5).map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Flexible(child: Text(e.key, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 10))), Text("${e.value}", style: TextStyle(color: themeColor, fontWeight: FontWeight.bold, fontSize: 10))]))).toList()]))
        )),
        if (carregando) Center(child: CircularProgressIndicator(color: themeColor, strokeWidth: 8)),
      ]),
    );
  }

  Widget _btn(String l, String v) {
    bool s = filtroAno == v;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: s ? themeColor : Colors.black.withOpacity(0.8), foregroundColor: s ? Colors.black : Colors.white, side: BorderSide(color: s ? Colors.transparent : themeColor.withOpacity(0.5))), onPressed: () { setState(() => filtroAno = v); if (pontoSelecionado != null) buscarCrimes(pontoSelecionado!); }, child: Text(l, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold))));
  }
}