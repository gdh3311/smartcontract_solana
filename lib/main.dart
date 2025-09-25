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
const stateSecretKeyBase58 = 'DLVvNymnZuru7BJCSknk7DxbksJZdhMBXYiFAJF1Afqd';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Solana Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Solana Contract Demo'),
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
  String? stateAddress; // stateAccount 대신 주소 문자열 사용
  Map<String, dynamic>? idl;
  bool _isInitialized = false;

  // State values for new contract
  int _value = 0;
  String _message = "";
  int _counter = 0;
  int _totalInteractions = 0;

  @override
  void initState() {
    super.initState();
    initSolana();
  }

  Future<void> initSolana() async {
    try {
      client = RpcClient('https://api.devnet.solana.com');

      final userKeyBytes = base58.decode(userSecretKeyBase58);
      user = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: userKeyBytes.sublist(0, 32)
      );
      print('Loaded user: ${user.address}');

      // PDA 주소를 변수에 저장
      stateAddress = await findStateAddress(user.publicKey);
      print('State address (PDA): $stateAddress');

      // IDL 읽기
      final jsonString = await rootBundle.loadString('assets/solana_contract.json');
      idl = jsonDecode(jsonString);

      setState(() {
        _isInitialized = true;
      });

      await readState();
    } catch (e) {
      print('Initialization error: $e');
    }
  }
  Future<String> findStateAddress(Ed25519HDPublicKey userPubkey) async {
    final seeds = [
      utf8.encode("state"),
      userPubkey.bytes,
    ];
    final pda = await Ed25519HDPublicKey.findProgramAddress(
        seeds: seeds,
        programId: Ed25519HDPublicKey.fromBase58(programId)
    );

    return pda.toString(); // PDA 주소 반환
  }
  Uint8List buildInstructionData(String methodName, {int? newValue, String? newMessage}) {
    final instruction = idl!['instructions'].firstWhere((ins) => ins['name'] == methodName);
    final discriminator = List<int>.from(instruction['discriminator']);

    Uint8List argsBytes = Uint8List(0);

    if (methodName == 'set_value' && newValue != null) {
      final buffer = ByteData(8);
      final low32 = newValue & 0xFFFFFFFF;
      final high32 = (newValue >> 32) & 0xFFFFFFFF;
      buffer.setUint32(0, low32, Endian.little);
      buffer.setUint32(4, high32, Endian.little);
      argsBytes = buffer.buffer.asUint8List();
    } else if (methodName == 'set_message' && newMessage != null) {
      final messageBytes = utf8.encode(newMessage);
      final buffer = ByteData(4 + messageBytes.length);
      buffer.setUint32(0, messageBytes.length, Endian.little);
      for (int i = 0; i < messageBytes.length; i++) {
        buffer.setUint8(4 + i, messageBytes[i]);
      }
      argsBytes = buffer.buffer.asUint8List();
    }

    return Uint8List.fromList([...discriminator, ...argsBytes]);
  }

  Future<void> initializeState() async {
    try {
      final data = buildInstructionData('initialize');
      // Ed25519HDPublicKey.createProgramAddress(seeds: seeds, programId: programId)
      // Ed25519HDPublicKey.createWithSeed(fromPublicKey: fromPublicKey, seed: seed, programId: programId)
      // Ed25519HDPublicKey.findProgramAddress(seeds: seeds, programId: programId)
      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(stateAddress!),
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
      final signature = await client.signAndSendTransaction(message, [user]); // user만 서명

      print('Initialize tx: $signature');
      await Future.delayed(Duration(seconds: 2));
      await readState();
    } catch (e) {
      print('Initialize error: $e');
    }
  }

  Future<void> setValue(int newValue) async {
    try {
      final data = buildInstructionData('set_value', newValue: newValue);

      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(stateAddress!),
              isSigner: false
          ),
          AccountMeta.readonly(pubKey: user.publicKey, isSigner: true), // user 추가 (PDA 시드에 필요)
        ],
        data: ByteArray(data),
      );

      final message = Message(instructions: [instruction]);
      final signature = await client.signAndSendTransaction(message, [user]);

      print('SetValue tx: $signature');
      await Future.delayed(Duration(seconds: 1));
      await readState();
    } catch (e) {
      print('SetValue error: $e');
    }
  }

  Future<void> setMessage(String newMessage) async {
    try {
      final data = buildInstructionData('set_message', newMessage: newMessage);

      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(stateAddress!),
              isSigner: false
          ),
          AccountMeta.readonly(pubKey: user.publicKey, isSigner: true),
        ],
        data: ByteArray(data),
      );

      final message = Message(instructions: [instruction]);
      final signature = await client.signAndSendTransaction(message, [user]);

      print('SetMessage tx: $signature');
      await Future.delayed(Duration(seconds: 1));
      await readState();
    } catch (e) {
      print('SetMessage error: $e');
    }
  }


  Future<void> incrementCounter() async {
    try {
      final data = buildInstructionData('increment_counter');

      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(stateAddress!),
              isSigner: false
          ),
          AccountMeta.readonly(pubKey: user.publicKey, isSigner: true),
        ],
        data: ByteArray(data),
      );

      final message = Message(instructions: [instruction]);
      final signature = await client.signAndSendTransaction(message, [user]);

      print('IncrementCounter tx: $signature');
      await Future.delayed(Duration(seconds: 1));
      await readState();
    } catch (e) {
      print('IncrementCounter error: $e');
    }
  }

  Future<void> readState() async {
    try {
      final response = await http.post(
        Uri.parse('https://api.devnet.solana.com'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "jsonrpc": "2.0",
          "id": 1,
          "method": "getAccountInfo",
          "params": [
            stateAddress!, // PDA 주소 사용
            {"encoding": "base64", "commitment": "confirmed"}
          ]
        }),
      );

      final data = jsonDecode(response.body);

      if (data['result']?['value']?['data'] != null) {
        final dataArray = data['result']['value']['data'][0];
        final dataBytes = base64.decode(dataArray);

        print('Account data length: ${dataBytes.length}');

        if (dataBytes.length >= 16) {
          int offset = 8; // Skip discriminator

          // Read value (u64)
          final valueBuffer = ByteData.sublistView(dataBytes, offset, offset + 8);
          final valueLow32 = valueBuffer.getUint32(0, Endian.little);
          final valueHigh32 = valueBuffer.getUint32(4, Endian.little);
          final value = valueLow32 + (valueHigh32 << 32);
          offset += 8;

          // Read message (String)
          final messageLengthBuffer = ByteData.sublistView(dataBytes, offset, offset + 4);
          final messageLength = messageLengthBuffer.getUint32(0, Endian.little);
          offset += 4;

          final messageBytes = dataBytes.sublist(offset, offset + messageLength);
          final message = utf8.decode(messageBytes);
          offset += messageLength;

          // Read counter (u64)
          final counterBuffer = ByteData.sublistView(dataBytes, offset, offset + 8);
          final counterLow32 = counterBuffer.getUint32(0, Endian.little);
          final counterHigh32 = counterBuffer.getUint32(4, Endian.little);
          final counter = counterLow32 + (counterHigh32 << 32);

          setState(() {
            _value = value;
            _message = message;
            _counter = counter;
            _totalInteractions = value + counter;
          });

          print('Read state - Value: $value, Message: "$message", Counter: $counter');
        }
      } else {
        print('Account not found - initialize first');
      }
    } catch (e) {
      print('Read state error: $e');
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
                        Text('Contract State', style: Theme.of(context).textTheme.headlineSmall),
                        SizedBox(height: 16),
                        Text('Value: $_value'),
                        Text('Message: "$_message"'),
                        Text('Counter: $_counter'),
                        Text('Total: $_totalInteractions'),
                      ],
                    ),
                  ),
                ),

                SizedBox(height: 20),

                ElevatedButton(
                  onPressed: initializeState,
                  child: Text('Initialize State'),
                ),

                SizedBox(height: 10),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () => setValue(_value + 1),
                      child: Text('Value +1'),
                    ),
                    ElevatedButton(
                      onPressed: incrementCounter,
                      child: Text('Counter +1'),
                    ),
                  ],
                ),

                SizedBox(height: 10),

                ElevatedButton(
                  onPressed: () => setMessage('Hello from Flutter!'),
                  child: Text('Set Message'),
                ),

                SizedBox(height: 10),

                ElevatedButton(
                  onPressed: readState,
                  child: Text('Read State'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}