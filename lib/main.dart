import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:audioplayers/audioplayers.dart'; // Para áudio

final clients = <WebSocket>[];
final Map<WebSocket, String> clientNames = {};

void main() {
  runApp(const TVBingoApp());
}

class TVBingoApp extends StatelessWidget {
  const TVBingoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark(useMaterial3: true),
      theme: ThemeData(
        fontFamily: 'Poppins',
      ),
      home: const BingoControlScreen(),
    );
  }
}

class BingoControlScreen extends StatefulWidget {
  const BingoControlScreen({super.key});

  @override
  State<BingoControlScreen> createState() => _BingoControlScreenState();
}

class _BingoControlScreenState extends State<BingoControlScreen> {
  var drawnNumbers = <int>[];
  String ipAddress = '';
  String? _serverError;
  Timer? _timer;
  bool _isRunning = false;
  final _random = Random();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioPlayer _musicPlayer = AudioPlayer();

  int? lastBall;

  @override
  void initState() {
    super.initState();
    _getLocalIp();
    _startWebSocketServer();
    _startBackgroundMusic();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _audioPlayer.dispose();
    _musicPlayer.dispose();
    super.dispose();
  }

  void _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            setState(() {
              ipAddress = addr.address;
            });
            return;
          }
        }
      }

      setState(() {
        ipAddress = 'IP não encontrado';
      });
    } catch (e) {
      setState(() {
        ipAddress = 'Erro ao obter IP: $e';
      });
    }
  }

  void _startWebSocketServer() async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 3000);
      print('Servidor WebSocket rodando na porta 3000');

      await for (HttpRequest req in server) {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          WebSocket socket = await WebSocketTransformer.upgrade(req);
          print('Novo cliente conectado: ${req.connectionInfo?.remoteAddress}');

          socket.listen(
            (data) {
              try {
                final decoded = jsonDecode(data);
                final type = decoded['type'];

                if (type == 'PLAYER_JOIN') {
                  final name = decoded['name'] ?? 'Jogador desconhecido';
                  clientNames[socket] = name;
                  clients.add(socket);
                  setState(() {}); // Atualiza a interface com o novo nome
                } else {
                  _handleClientMessage(data, socket);
                }
              } catch (e) {
                print('Erro ao decodificar mensagem inicial: $e');
              }
            },
            onDone: () {
              clients.remove(socket);
              clientNames.remove(socket);
              setState(() {});
            },
          );
        } else {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
        }
      }
    } catch (e) {
      print('Erro ao iniciar servidor WebSocket: $e');
      setState(() {
        _serverError = 'Erro ao iniciar servidor WebSocket: $e';
      });
    }
  }

  void _handleClientMessage(dynamic data, WebSocket socket) {
    try {
      final decoded = jsonDecode(data);
      final type = decoded['type'];

      if (type == 'BINGO') {
        List<dynamic> clientNumbers = decoded['numbers'] ?? [];
        final playerId = decoded['playerId'] ?? 'Jogador desconhecido';

        final isWinner = _checkBingo(clientNumbers.cast<int>());
        if (isWinner) {
          _broadcast(jsonEncode({
            'type': 'BINGO_RESULT',
            'result': 'WIN',
            'playerId': playerId,
            'message': 'Bingo válido! Jogo encerrado.'
          }));

          _stopDrawing();
        } else {
          socket.add(jsonEncode({
            'type': 'BINGO_RESULT',
            'result': 'FAIL',
            'message': 'Bingo inválido. Continue jogando!'
          }));
        }
      }
    } catch (e) {
      print('Erro ao processar mensagem do cliente: $e');
    }
  }

  bool _checkBingo(List<int> clientNumbers) {
    for (var n in clientNumbers) {
      if (!drawnNumbers.contains(n)) {
        return false;
      }
    }
    return true;
  }

  void _broadcast(String data) {
    for (var client in clients) {
      if (client.readyState == WebSocket.open) {
        client.add(data);
      }
    }
  }

  Future<void> _playNumberSound() async {
    try {
      await _audioPlayer.play(AssetSource('audio/ball_sound.mp3'));
    } catch (e) {
      print('Erro ao tocar som: $e');
    }
  }

  Future<void> _startBackgroundMusic() async {
    try {
      await _musicPlayer.setReleaseMode(ReleaseMode.loop);
      await _musicPlayer.setVolume(0.4);
      await _musicPlayer.play(AssetSource('audio/background_music.mp3'));
    } catch (e) {
      print('Erro ao tocar música de fundo: $e');
    }
  }

  void _drawNumber() {
    if (drawnNumbers.length >= 75) {
      _stopDrawing();
      return;
    }

    int num;
    do {
      num = _random.nextInt(75) + 1;
    } while (drawnNumbers.contains(num));

    setState(() {
      if (lastBall != null) {
        drawnNumbers.insert(
            0, lastBall!); // move a bola anterior para o histórico
        if (drawnNumbers.length > 5) {
          drawnNumbers = drawnNumbers.sublist(0, 5); // mantém 5 bolas no máximo
        }
      }
      lastBall = num; // define a nova última bola
    });

    _broadcast(jsonEncode({"type": "DRAW", "number": num}));
    _playNumberSound();
  }

  void _startDrawing() {
    if (_isRunning) return;

    setState(() {
      _isRunning = true;
      drawnNumbers.clear();
    });

    _timer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (drawnNumbers.length >= 75) {
        _stopDrawing();
        return;
      }
      _drawNumber();
    });
  }

  void _stopDrawing() {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _isRunning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final connectedClientsCount =
        clients.where((c) => c.readyState == WebSocket.open).length;

    if (_serverError != null) {
      return Scaffold(
        body: Center(
          child: Text(
            _serverError!,
            style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.red,
                fontSize: 20,
                fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final String lastBallText = lastBall != null ? '$lastBall' : '';

    return Scaffold(
      appBar: AppBar(
          title: const Text(
        'Bingo Family',
        style: TextStyle(
          fontFamily: 'Poppins',
          fontSize: 32,
          color: Colors.teal,
          fontWeight: FontWeight.bold,
        ),
      )),
      body: Row(
        children: [
          // Container esquerdo
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),
                  Text(
                    'IP da TV: $ipAddress',
                    style: const TextStyle(fontFamily: 'Poppins', fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  if (ipAddress.isNotEmpty && !ipAddress.startsWith('Erro'))
                    QrImageView(
                      data: ipAddress,
                      version: QrVersions.auto,
                      size: 120.0,
                      backgroundColor: Colors.white,
                    ),
                  const SizedBox(height: 24),
                  Text(
                    'Dispositivos conectados: $connectedClientsCount',
                    style: const TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: clients.length,
                      itemBuilder: (context, index) {
                        final client = clients[index];
                        final name =
                            clientNames[client] ?? 'Cliente ${index + 1}';
                        final status = client.readyState == WebSocket.open
                            ? 'conectado'
                            : 'desconectado';

                        return Text(
                          '$name: $status',
                          style: const TextStyle(
                              fontFamily: 'Poppins', fontSize: 14),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _isRunning ? null : _startDrawing,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Iniciar bingo',
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                      onPressed: _isRunning ? _stopDrawing : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Parar',
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      )),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Container(
              width: 140,
              height: 140,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black26, blurRadius: 12, spreadRadius: 3),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                lastBallText,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ),
          ),

          // Container direito
          Expanded(
            flex: 2,
            child: Container(
              height: 68, // altura fixa como você pediu
              width: double.infinity,
              alignment: Alignment.center,
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: drawnNumbers.reversed
                    .take(7)
                    .map(
                      (num) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '$num',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
