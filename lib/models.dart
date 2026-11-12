import 'dart:typed_data';

/// 上传状态
enum UploadStatus { pending, uploading, done, error }

/// 保存期限选项：键与 Relavo 接口的 expiry 字段完全一致。
const Map<String, String> expiryLabels = {
  '1h': '1 小时',
  '24h': '24 小时',
  '7d': '7 天',
  '30d': '30 天',
  'never': '永久保存',
};

/// 保存期限的说明文字
const Map<String, String> expiryHints = {
  '1h': '1 小时后自动删除',
  '24h': '24 小时后自动删除',
  '7d': '7 天后自动删除',
  '30d': '30 天后自动删除',
  'never': '永不自动删除',
};

class UploadItem {
  UploadItem({
    required this.id,
    required this.name,
    required this.mime,
    required this.bytes,
    required this.thumbBytes,
  }) : size = bytes.length;

  final String id;
  final String name;
  final String mime;

  /// 已做隐私处理、待上传的图片数据
  final Uint8List bytes;

  /// 列表用的小缩略图
  final Uint8List thumbBytes;

  /// 上传后的实际大小
  final int size;

  UploadStatus status = UploadStatus.pending;
  double progress = 0;
  String? url; // 图片直链 https://relavo.net/i/xxx
  String? viewUrl; // 查看页 https://relavo.net/v/xxx
  String? imageId;
  String? deleteToken;
  String? expiresAt;
  String? error;

  bool get isDone => status == UploadStatus.done;
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}
