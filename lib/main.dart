import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

final clients = <WebSocket>[];

void main() {
  runApp(const TVBingoApp());
}

class TVBingoApp extends StatelessWidget {
  const TVBingoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: BingoControlScreen(),
    );
  }
}

class BingoControlScreen extends StatefulWidget {
  const BingoControlScreen({super.key});

  @override
  State<BingoControlScreen> createState() => _BingoControlScreenState();
}

class _BingoControlScreenState extends State<BingoControlScreen> {
  final drawnNumbers = <int>[];
  String ipAddress = '';

  @override
  void initState() {
    super.initState();
    _getLocalIp();
    _startWebSocketServer();
  }

  /// Obtém o IP local da TV Android (não loopback e válido)
  Future<void> _getLocalIp() async {
    try {
      for (var interface in await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      )) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            setState(() {
              ipAddress = addr.address;
            });
            return;
          }
        }
      }
      setState(() => ipAddress = 'IP não encontrado');
    } catch (e) {
      setState(() => ipAddress = 'Erro ao obter IP');
      print('Erro ao obter IP: $e');
    }
  }

  void _startWebSocketServer() async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 3000);
      print('Servidor WebSocket rodando na porta 3000');

      await for (HttpRequest req in server) {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          WebSocket socket = await WebSocketTransformer.upgrade(req);
          clients.add(socket);
          print('Novo cliente conectado: ${req.connectionInfo?.remoteAddress}');

          socket.listen(
            (data) {
              print('Recebido do cliente: $data');
              _broadcast(data);
            },
            onDone: () {
              clients.remove(socket);
              print('Cliente desconectado');
            },
          );
        } else {
          req.response.statusCode = HttpStatus.forbidden;
          await req.response.close();
        }
      }
    } catch (e) {
      print('Erro ao iniciar servidor WebSocket: $e');
    }
  }

  void _broadcast(String data) {
    for (var client in clients) {
      if (client.readyState == WebSocket.open) {
        client.add(data);
      }
    }
  }

  void _drawNumber() {
    if (drawnNumbers.length >= 75) return; // max 75 números

    int num;
    final random = Random();
    do {
      num = random.nextInt(75) + 1;
    } while (drawnNumbers.contains(num));

    setState(() {
      drawnNumbers.add(num);
    });

    _broadcast(jsonEncode({"type": "DRAW", "number": num}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Controle do Bingo (TV)')),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: _drawNumber,
            child: const Text('Sortear número'),
          ),
          const SizedBox(height: 10),
          Text(
            'IP da TV: $ipAddress',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          if (ipAddress.isNotEmpty && !ipAddress.startsWith('Erro'))
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: QrImageView(
                data: ipAddress,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
          Expanded(
            child: Wrap(
              children: drawnNumbers
                  .map((n) => Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Chip(label: Text('$n')),
                      ))
                  .toList(),
            ),
          )
        ],
      ),
    );
  }
}