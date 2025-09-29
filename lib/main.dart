import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:bs58/bs58.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

const programId = '3NEr6ZiHYsW6eP2w6tk84yoVdWsRiDyYoe5qxY6qrTKL';
const userSecretKeyBase58 = 'Mxj2LkCF8bQuJx21btcxoqC4yBG7D7RuHP1We3weMYXMoumc2QcAhnLs71frdp4CKrhgHq5bc2zSj1hpRpJSMGP';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Solana Mapping Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Hash-based Balance System'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late RpcClient client;
  late Ed25519HDKeyPair user;
  Map<String, dynamic>? idl;
  bool _isInitialized = false;

  String _lastHashKey = "";
  int _myBalanceLamports = 0;
  int _mappingBalanceLamports = 0;

  final TextEditingController _amountController = TextEditingController(text: "0.1"); // SOL 단위
  final TextEditingController _withdrawHashController = TextEditingController();

  @override
  void initState() {
    super.initState();
    initSolana();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _withdrawHashController.dispose();
    super.dispose();
  }

  Future<void> initSolana() async {
    try {
      client = RpcClient('https://api.devnet.solana.com');

      final userKeyBytes = base58.decode(userSecretKeyBase58);
      user = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: userKeyBytes.sublist(0, 32)
      );

      print('User address: ${user.publicKey}');
      await getMyBalance();

      final jsonString = await rootBundle.loadString('assets/solana_contract.json');
      idl = jsonDecode(jsonString);

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      print('Initialization error: $e');
    }
  }

  Future<void> getMyBalance() async {
    try {
      final balance = await client.getBalance(user.publicKey.toBase58());
      setState(() {
        _myBalanceLamports = balance.value;
      });
      print('My Balance: ${_myBalanceLamports / 1e9} SOL');
    } catch (e) {
      print('Get balance error: $e');
    }
  }

  String generateHashKey() {
    final random = DateTime.now().microsecondsSinceEpoch.toString() +
        user.publicKey.toString();
    final bytes = utf8.encode(random);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 32);
  }

  Future<String> findBalanceAddress(String hashKey) async {
    final seeds = [
      utf8.encode("balance"),
      utf8.encode(hashKey),
    ];
    final pda = await Ed25519HDPublicKey.findProgramAddress(
        seeds: seeds,
        programId: Ed25519HDPublicKey.fromBase58(programId)
    );
    return pda.toBase58();
  }

  Uint8List buildInstructionData(String methodName, {String? hashKey, int? amount}) {
    final instruction = idl!['instructions'].firstWhere((ins) => ins['name'] == methodName);
    final discriminator = List<int>.from(instruction['discriminator']);

    Uint8List argsBytes = Uint8List(0);

    if (methodName == 'deposit' && hashKey != null && amount != null) {
      final keyBytes = utf8.encode(hashKey);
      final buffer = ByteData(4 + keyBytes.length + 8);

      buffer.setUint32(0, keyBytes.length, Endian.little);
      for (int i = 0; i < keyBytes.length; i++) {
        buffer.setUint8(4 + i, keyBytes[i]);
      }

      final amountOffset = 4 + keyBytes.length;
      final low32 = amount & 0xFFFFFFFF;
      final high32 = (amount >> 32) & 0xFFFFFFFF;
      buffer.setUint32(amountOffset, low32, Endian.little);
      buffer.setUint32(amountOffset + 4, high32, Endian.little);

      argsBytes = buffer.buffer.asUint8List();
    } else if (methodName == 'withdraw' && hashKey != null) {
      final keyBytes = utf8.encode(hashKey);
      final buffer = ByteData(4 + keyBytes.length);
      buffer.setUint32(0, keyBytes.length, Endian.little);
      for (int i = 0; i < keyBytes.length; i++) {
        buffer.setUint8(4 + i, keyBytes[i]);
      }
      argsBytes = buffer.buffer.asUint8List();
    }

    return Uint8List.fromList([...discriminator, ...argsBytes]);
  }

  Future<void> deposit(double amountSol) async {
    try {
      final amountLamports = (amountSol * 1e9).toInt();
      if (amountLamports <= 0) return;

      final hashKey = generateHashKey();
      final balanceAddress = await findBalanceAddress(hashKey);

      final data = buildInstructionData('deposit', hashKey: hashKey, amount: amountLamports);

      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(balanceAddress),
              isSigner: false
          ),
          AccountMeta.writeable(pubKey: user.publicKey, isSigner: true),
          AccountMeta.readonly(
              pubKey: Ed25519HDPublicKey.fromBase58('11111111111111111111111111111111'),
              isSigner: false
          ),
        ],
        data: ByteArray(data),
      );

      final message = Message(instructions: [instruction]);
      final signature = await client.signAndSendTransaction(message, [user]);

      print('Deposit tx: $signature');
      print('Generated Hash Key: $hashKey');

      setState(() {
        _lastHashKey = hashKey;
      });

      await Future.delayed(Duration(seconds: 2));
      await getMyBalance();
      await checkBalance(hashKey);
    } catch (e) {
      print('Deposit error: $e');
    }
  }

  Future<void> withdraw(String hashKey) async {
    try {
      if (hashKey.isEmpty) {
        print('Hash key is empty');
        return;
      }

      final balanceAddress = await findBalanceAddress(hashKey);
      final data = buildInstructionData('withdraw', hashKey: hashKey);

      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(balanceAddress),
              isSigner: false
          ),
          AccountMeta.writeable(pubKey: user.publicKey, isSigner: true),
        ],
        data: ByteArray(data),
      );

      final message = Message(instructions: [instruction]);
      final signature = await client.signAndSendTransaction(message, [user]);

      print('Withdraw tx: $signature');
      await Future.delayed(Duration(seconds: 2));

      setState(() {
        _mappingBalanceLamports = 0;
      });

      await getMyBalance();
    } catch (e) {
      print('Withdraw error: $e');
    }
  }

  Future<void> checkBalance(String hashKey) async {
    try {
      final balanceAddress = await findBalanceAddress(hashKey);

      final response = await http.post(
        Uri.parse('https://api.devnet.solana.com'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "jsonrpc": "2.0",
          "id": 1,
          "method": "getAccountInfo",
          "params": [
            balanceAddress,
            {"encoding": "base64", "commitment": "confirmed"}
          ]
        }),
      );

      final data = jsonDecode(response.body);

      if (data['result']?['value']?['data'] != null) {
        final dataArray = data['result']['value']['data'][0];
        final dataBytes = base64.decode(dataArray);

        if (dataBytes.length >= 8) {
          int offset = 8;

          final keyLengthBuffer = ByteData.sublistView(dataBytes, offset, offset + 4);
          final keyLength = keyLengthBuffer.getUint32(0, Endian.little);
          offset += 4;

          final keyBytes = dataBytes.sublist(offset, offset + keyLength);
          final storedKey = utf8.decode(keyBytes);
          offset += keyLength;

          final balanceBuffer = ByteData.sublistView(dataBytes, offset, offset + 8);
          final balanceLow32 = balanceBuffer.getUint32(0, Endian.little);
          final balanceHigh32 = balanceBuffer.getUint32(4, Endian.little);
          final balance = balanceLow32 + (balanceHigh32 << 32);

          setState(() {
            _lastHashKey = storedKey;
            _mappingBalanceLamports = balance;
          });

          print('Mapping - Key: "$storedKey", Balance: ${balance / 1e9} SOL');
        }
      } else {
        print('No balance found for this key');
        setState(() {
          _mappingBalanceLamports = 0;
        });
      }
    } catch (e) {
      print('Check balance error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (!_isInitialized)
                const CircularProgressIndicator()
              else ...[
                Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text('My Wallet', style: Theme.of(context).textTheme.headlineSmall),
                        SizedBox(height: 16),
                        Text('Balance: ${(_myBalanceLamports / 1e9).toStringAsFixed(4)} SOL',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 20),

                Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text('Mapping State', style: Theme.of(context).textTheme.headlineSmall),
                        SizedBox(height: 16),
                        Text('Last Key: ${_lastHashKey.isEmpty ? "None" : _lastHashKey}'),
                        Text('Balance: ${(_mappingBalanceLamports / 1e9).toStringAsFixed(4)} SOL'),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 20),

                TextField(
                  controller: _amountController,
                  decoration: InputDecoration(
                    labelText: 'Amount (SOL)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),

                SizedBox(height: 20),

                ElevatedButton(
                  onPressed: () {
                    final amountSol = double.tryParse(_amountController.text) ?? 0;
                    if (amountSol > 0) {
                      deposit(amountSol);
                    }
                  },
                  child: Text('Deposit (Create Mapping Entry)'),
                ),

                SizedBox(height: 30),

                Divider(),

                SizedBox(height: 10),

                Text('Withdraw Section', style: Theme.of(context).textTheme.titleLarge),

                SizedBox(height: 10),

                TextField(
                  controller: _withdrawHashController,
                  decoration: InputDecoration(
                    labelText: 'Hash Key',
                    border: OutlineInputBorder(),
                  ),
                ),

                SizedBox(height: 10),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        final hashKey = _withdrawHashController.text;
                        if (hashKey.isNotEmpty) {
                          withdraw(hashKey);
                        }
                      },
                      child: Text('Withdraw'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        final hashKey = _withdrawHashController.text;
                        if (hashKey.isNotEmpty) {
                          checkBalance(hashKey);
                        }
                      },
                      child: Text('Check Balance'),
                    ),
                  ],
                ),

                SizedBox(height: 20),

                Text(
                  'Like EVM mapping(hash => uint): Enter hash key to access balance',
                  style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
