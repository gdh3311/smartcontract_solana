import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:solana/base58.dart';
import 'package:web3dart/crypto.dart'; // keccak256용
import 'package:bs58/bs58.dart';

class SolanaHashChain {
  /// 하이브리드 해시 함수 (SHA256 x3 + Keccak x2)
  static const List<String> H1_DOMAIN = ["winnipeg"];
  static const List<String> H2_DOMAIN = ["anonymous_pool_v1"];

  static String _createH1Pattern(String input) {
    Uint8List current = utf8.encode(input);
    List<int> domainBytes = H1_DOMAIN.expand((s) => utf8.encode(s)).toList();
    current = Uint8List.fromList([...domainBytes, ...current]);

    // S-K-S-K 패턴
    current = Uint8List.fromList(sha256.convert(current).bytes);
    current = keccak256(current);
    current = Uint8List.fromList(sha256.convert(current).bytes);
    current = keccak256(current);

    return base58.encode(current);
  }

  static String _createH2Pattern(String h1Base58) {
    final h1Bytes = base58.decode(h1Base58);
    List<int> domainBytes = H2_DOMAIN.expand((s) => utf8.encode(s)).toList();

    var current = Uint8List.fromList([...domainBytes, ...h1Bytes]);

    print('=== H2 Calculation Debug ===');
    print('Initial length: ${current.length}');

    for (int i = 0; i < 5; i++) {
      final isEven = current.length % 2 == 0;

      if (isEven) {
        current = keccak256(current);
        print('Step ${i+1}: Keccak256 (even length), new length: ${current.length}');
      } else {
        current = Uint8List.fromList(sha256.convert(current).bytes);
        print('Step ${i+1}: SHA256 (odd length), new length: ${current.length}');
      }
    }

    return base58.encode(current);
  }
  static Map<String, String> createDepositChain({
    required String userPublicKey,
    int? nonce,
  }) {
    final secret = generateSecret(userPublicKey, nonce);

    final h1 = _createH1Pattern(secret);

    final h2 = _createH2Pattern(h1);

    return {
      'secret': secret, // 원본 (절대 공개 X)
      'depositHash': h1, // 출금 코드 (B에게 전달)
      'withdrawHash': h2, // PDA 생성용 (컨트랙트 저장)
    };
  }

  /// 시크릿 생성 함수
  static String generateSecret(String userPublicKey, [int? customNonce]) {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final nonce = customNonce ?? timestamp;
    final combined = '$userPublicKey:$nonce:${timestamp}';

    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);

    return digest.toString();
  }

  static String  prepareWithdraw(String withdrawCode) {
    // H1 → H2 계산
    return _createH2Pattern(withdrawCode);
  }
}
