import 'package:lottie/lottie.dart';

/// Decodes a DotLottie archive by selecting its animation JSON instead of
/// `manifest.json`, which is commonly the first JSON entry in the archive.
Future<LottieComposition?> decodeDotLottie(List<int> bytes) {
  return LottieComposition.decodeZip(
    bytes,
    filePicker: (files) => files.firstWhere((file) {
      final normalizedName = file.name.replaceAll(r'\', '/').toLowerCase();
      return normalizedName.startsWith('animations/') &&
          normalizedName.endsWith('.json');
    }),
  );
}
