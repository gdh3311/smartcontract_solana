import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:solana/encoder.dart';
import 'package:solana/dto.dart' as dto;
import 'package:solana/solana.dart';
import 'package:bs58/bs58.dart';
import 'package:http/http.dart' as http;
import 'package:solanacontext/hashchain.dart';

void main() {
  runApp(const MyApp());
}

// hkJegVqLUSSSh85QPZAvmWqC5FQFGK1teJxNjMqiWyDKf8bvhqiuSJhsjKuBVepS2nVqDJhHpsJT3Jb8wxzPinD
const programId = '3NEr6ZiHYsW6eP2w6tk84yoVdWsRiDyYoe5qxY6qrTKL';
const userSecretKeyBase58 =
    'Mxj2LkCF8bQuJx21btcxoqC4yBG7D7RuHP1We3weMYXMoumc2QcAhnLs71frdp4CKrhgHq5bc2zSj1hpRpJSMGP';
const userSecretKey2Base58 =
    "3KQRrA6wna6UQPEGKVRaPPinh5DVDY4WCAVkpPhNRRC9XRR6JjvWagxXzQTzokjuhhqSfo4AvZ6UoUMoXZkzyaGn";
const adminSecretKeyBase58 =
    "hkJegVqLUSSSh85QPZAvmWqC5FQFGK1teJxNjMqiWyDKf8bvhqiuSJhsjKuBVepS2nVqDJhHpsJT3Jb8wxzPinD";

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
  double _mappingBalanceLamports = 0;
  bool _initialized = false;

  final TextEditingController _amountController =
      TextEditingController(text: "0.1");
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

      final userKeyBytes = base58.decode(userSecretKey2Base58);
      user = await Ed25519HDKeyPair.fromPrivateKeyBytes(
          privateKey: userKeyBytes.sublist(0, 32));

      print('User address: ${user.publicKey}');
      await getMyBalance();

      final jsonString =
          await rootBundle.loadString('assets/anonymous_pool.json');
      idl = jsonDecode(jsonString);

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      print('Initialization error: $e');
    }
  }

  Future<void> initializePool() async {
    RpcClient server = RpcClient('https://api.devnet.solana.com');
    final keyBytes = base58.decode(adminSecretKeyBase58);
    Ed25519HDKeyPair admin = await Ed25519HDKeyPair.fromPrivateKeyBytes(
        privateKey: keyBytes.sublist(0, 32));

    final jsonString =
        await rootBundle.loadString('assets/anonymous_pool.json');
    idl = jsonDecode(jsonString);
    setState(() {});
    final poolAddress = await findPoolAddress();
    final data = buildInstructionData('initialize');

    final instruction = Instruction(
      programId: Ed25519HDPublicKey.fromBase58(programId),
      accounts: [
        AccountMeta.writeable(
            pubKey: Ed25519HDPublicKey.fromBase58(poolAddress),
            isSigner: false),
        AccountMeta.writeable(pubKey: admin.publicKey, isSigner: true),
        AccountMeta.readonly(
            pubKey: Ed25519HDPublicKey.fromBase58(
                '11111111111111111111111111111111'),
            isSigner: false),
      ],
      data: ByteArray(data),
    );

    final message = Message(instructions: [instruction]);
    final signature = await server.signAndSendTransaction(message, [admin]);
    setState(() {
      _initialized = true;
    });
    print('✅ Pool initialized: $signature');
  }

  Future<bool> isPoolInitialized() async {
    try {
      final poolAddress = await findPoolAddress();
      print("Pool address: $poolAddress");

      final info = await client.getAccountInfo(
        poolAddress,
        encoding: dto.Encoding.base64,
      );
      return info.value != null && info.value!.data != null;
    } catch (e) {
      print("Pool not initialized or error: $e");
      return false;
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

  Future<String> findCommitmentAddress(Uint8List commitment) async {
    final seeds = [
      utf8.encode("commitment"),
      commitment,
    ];

    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: seeds,
      programId: Ed25519HDPublicKey.fromBase58(programId),
    );
    return pda.toBase58();
  }

  Future<String> findPoolAddress() async {
    final seeds = [utf8.encode("pool")];
    final pda = await Ed25519HDPublicKey.findProgramAddress(
      seeds: seeds,
      programId: Ed25519HDPublicKey.fromBase58(programId),
    );
    return pda.toBase58();
  }

  Uint8List buildInstructionData(String methodName,
      {Uint8List? hashKey, int? amount}) {
    final instruction =
        idl!['instructions'].firstWhere((ins) => ins['name'] == methodName);
    final discriminator = List<int>.from(instruction['discriminator']);

    Uint8List argsBytes = Uint8List(0);

    if (methodName == 'deposit' && hashKey != null && amount != null) {
      final buffer = ByteData(32 + 8); // 32 bytes hash + 8 bytes amount
      for (int i = 0; i < 32; i++) {
        buffer.setUint8(i, hashKey[i]);
      }
      buffer.setUint64(32, amount, Endian.little);

      argsBytes = buffer.buffer.asUint8List();
    } else if (methodName == 'withdraw' && hashKey != null) {
      final buffer = ByteData(32);
      for (int i = 0; i < 32; i++) {
        buffer.setUint8(i, hashKey[i]);
      }
      argsBytes = buffer.buffer.asUint8List();
    }

    return Uint8List.fromList([...discriminator, ...argsBytes]);
  }

  Future<void> deposit(double amountSol) async {
    final poolAddress = await findPoolAddress();
    final hashChain = SolanaHashChain.createDepositChain(
        userPublicKey: user.publicKey.toBase58());
    final h1 = hashChain["depositHash"]!;
    final h2 = hashChain["withdrawHash"]!;
    final h2Bytes = base58.decode(h2);
    final commitmentAddress = await findCommitmentAddress(h2Bytes);

    final amountLamports = (amountSol * 1e9).toInt();
    final data = buildInstructionData('deposit',
        hashKey: h2Bytes, amount: amountLamports);

    final instruction = Instruction(
      programId: Ed25519HDPublicKey.fromBase58(programId),
      accounts: [
        AccountMeta.writeable(
            pubKey: Ed25519HDPublicKey.fromBase58(poolAddress),
            isSigner: false),
        AccountMeta.writeable(
            pubKey: Ed25519HDPublicKey.fromBase58(commitmentAddress),
            isSigner: false),
        AccountMeta.writeable(pubKey: user.publicKey, isSigner: true),
        AccountMeta.readonly(
            pubKey: Ed25519HDPublicKey.fromBase58(
                '11111111111111111111111111111111'),
            isSigner: false),
      ],
      data: ByteArray(data),
    );

    final message = Message(instructions: [instruction]);
    final signature = await client.signAndSendTransaction(message, [user]);
    print('✅ Deposit Transaction: $signature');
    print('🔹 Hash1 (Deposit Hash): $h1');
    print('🔹 Hash2 (Withdraw Hash): $h2');
    print('🔹 Commitment PDA: $commitmentAddress');
    print('💰 Amount: $amountSol SOL (${amountLamports} lamports)');
  }

  Future<void> withdraw(String h1Base58) async {
    try {
      // H1 → H2 변환
      final h1Bytes = base58.decode(h1Base58);
      final h2Base58 = SolanaHashChain.prepareWithdraw(h1Base58);
      final h2Bytes = base58.decode(h2Base58);

      // PDA 조회
      final poolPDA = await findPoolAddress();
      final commitmentPDA = await findCommitmentAddress(h2Bytes);

      final info = await client.getAccountInfo(
        commitmentPDA,
        encoding: dto.Encoding.base58,
      );
      if (info.value == null) {
        print('Commitment not found!');
        return;
      }

      // instruction 데이터 생성
      final data = buildInstructionData('withdraw', hashKey: h1Bytes);

      final instruction = Instruction(
        programId: Ed25519HDPublicKey.fromBase58(programId),
        accounts: [
          // 1. pool PDA
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(poolPDA),
              isSigner: false),

          // 2. commitment_account PDA
          AccountMeta.writeable(
              pubKey: Ed25519HDPublicKey.fromBase58(commitmentPDA),
              isSigner: false),

          // 3. recipient (출금 받을 주소)
          AccountMeta.writeable(
              pubKey: user.publicKey,  // 또는 다른 수신 주소
              isSigner: false),

          // 4. user (서명자, lamports 지불)
          AccountMeta.writeable(pubKey: user.publicKey, isSigner: true),

          // 5. system_program
          AccountMeta.readonly(
              pubKey: Ed25519HDPublicKey.fromBase58(
                  '11111111111111111111111111111111'),
              isSigner: false),
        ],
        data: ByteArray(data),
      );

      // 트랜잭션 전송
      final message = Message(instructions: [instruction]);
      final signature = await client.signAndSendTransaction(message, [user]);

      print('✅ Withdraw Transaction: $signature');
      print('   H1: $h1Base58');
      print('   H2: $h2Base58');

      await getMyBalance();
    } catch (e) {
      print('❌ Withdraw error: $e');
    }
  }

  Future<String> findNullifierAddress(Uint8List h1Bytes) async {
    final programPubkey = Ed25519HDPublicKey.fromBase58(programId);
    final seeds = [utf8.encode('nullifier'), h1Bytes];
    final pda = await Ed25519HDPublicKey.findProgramAddress(
        seeds: seeds, programId: programPubkey);
    return pda.toBase58();
  }

  Future<void> checkBalance(String hashKey) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.devnet.solana.com'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "jsonrpc": "2.0",
          "id": 1,
          "method": "getAccountInfo",
          "params": [
            hashKey,
            {"encoding": "base64", "commitment": "confirmed"}
          ]
        }),
      );

      final data = jsonDecode(response.body);
      print(data.toString());
      final accountInfo = data['result']?['value'];
      if (accountInfo == null) {
        print('No balance found for this key');
        setState(() {
          _mappingBalanceLamports = 0;
        });
        return;
      }

      final accountDataBase64 = accountInfo['data'][0];
      final accountData = base64.decode(accountDataBase64);

      final storedKey = accountData.sublist(0, 32);
      final totalLamports = data['result']['value']['lamports'] as int;
      final balanceSol = totalLamports / 1e9;
      setState(() {
        _lastHashKey = base58.encode(storedKey); // 화면 표시용
        _mappingBalanceLamports = balanceSol;
      });

      print(
          'Mapping - Key: ${base58.encode(storedKey)}, Balance: $balanceSol SOL');
    } catch (e) {
      print('Check balance error: $e');
      setState(() {
        _mappingBalanceLamports = 0;
      });
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
                        Text('My Wallet',
                            style: Theme.of(context).textTheme.headlineSmall),
                        SizedBox(height: 16),
                        Text(
                            'Balance: ${(_myBalanceLamports / 1e9).toStringAsFixed(4)} SOL',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
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
                        Text('Mapping State',
                            style: Theme.of(context).textTheme.headlineSmall),
                        SizedBox(height: 16),
                        Text(
                            'Last Key: ${_lastHashKey.isEmpty ? "None" : _lastHashKey}'),
                        Text(
                            'Balance: ${(_mappingBalanceLamports).toStringAsFixed(4)} SOL'),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        final d = await isPoolInitialized();
                        if (!d) {
                          await initializePool();
                        }
                      },
                      child: Text('Init'),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        final amountSol =
                            double.tryParse(_amountController.text) ?? 0;
                        if (amountSol > 0) {
                          deposit(amountSol);
                        }
                      },
                      child: Text('Deposit (Create Mapping Entry)'),
                    ),
                  ],
                ),
                SizedBox(height: 30),
                Divider(),
                SizedBox(height: 10),
                Text('Withdraw Section',
                    style: Theme.of(context).textTheme.titleLarge),
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
                  'This Pre-Pre-Pre-Pre-Pre alpha Stage',
                  style: TextStyle(
                      color: Colors.blue, fontWeight: FontWeight.bold),
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
//3eafc1b70d3385a18f6b6dc2f97c8b64 0.1 sol
//100d53ef7309361a61d491cea195fcb3
