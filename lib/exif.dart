import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 清除 JPEG / PNG 的 EXIF、GPS、相机型号等隐私元数据：
/// 解码后重新编码，元数据不会带入新文件，同时按 EXIF 方向校正画面。
/// GIF / WebP 保持原文件上传，由服务端自动清除元数据。
Uint8List stripMetadata(Uint8List bytes, String mime) {
  if (mime != 'image/jpeg' && mime != 'image/png') return bytes;
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final oriented = img.bakeOrientation(decoded);
    if (mime == 'image/jpeg') {
      return Uint8List.fromList(img.encodeJpg(oriented, quality: 92));
    }
    return Uint8List.fromList(img.encodePng(oriented));
  } catch (_) {
    return bytes;
  }
}

/// 生成列表用的小缩略图（宽 240px），失败时返回原图。
Uint8List makeThumbnail(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final thumb = img.copyResize(decoded, width: 240);
    return Uint8List.fromList(img.encodeJpg(thumb, quality: 80));
  } catch (_) {
    return bytes;
  }
}
