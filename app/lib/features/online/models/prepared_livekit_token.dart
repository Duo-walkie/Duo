import 'package:one_one_app/one_one.dart';

// Prefetched LiveKit token + the session ids it was issued under.
class PreparedLiveKitToken {
  const PreparedLiveKitToken({
    required this.response,
    required this.serviceSessionId,
    required this.livekitSessionId,
  });

  final LiveKitTokenResponse response;
  final String serviceSessionId;
  final String livekitSessionId;

  static const int safetySeconds = 30;

  bool isUsableAt(int nowSeconds) =>
      response.expiresAt > nowSeconds + safetySeconds;
}
