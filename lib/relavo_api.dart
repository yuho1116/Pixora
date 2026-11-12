import 'package:dio/dio.dart';

/// Relavo 真实接口（已于 2026-11-12 实测验证）：
/// - 上传：POST https://relavo.net/api/upload
///   multipart 字段：expiry（1h / 24h / 7d / 30d / never），files（一次一张图片）
///   返回 JSON：urls（查看页）、image_urls（图片直链）、image_ids、
///   delete_tokens、expires_at
/// - 删除：POST https://relavo.net/api/delete
///   multipart 字段：image_id、token，成功返回 {"status":"deleted"}
/// - EXIF / GPS 等元数据由服务端在上传时自动清除。
class RelavoUploadResult {
  RelavoUploadResult({
    required this.directUrl,
    this.viewUrl,
    this.imageId,
    this.deleteToken,
    this.expiresAt,
  });

  final String directUrl;
  final String? viewUrl;
  final String? imageId;
  final String? deleteToken;
  final String? expiresAt;
}

class RelavoApi {
  RelavoApi()
      : _dio = Dio(BaseOptions(
          baseUrl: 'https://relavo.net',
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(minutes: 5),
          receiveTimeout: const Duration(seconds: 60),
        ));

  final Dio _dio;

  Future<RelavoUploadResult> upload({
    required List<int> bytes,
    required String filename,
    required String mime,
    required String expiry,
    required void Function(int sent, int total) onSendProgress,
  }) async {
    // 移动网络偶尔抖动：连接类错误自动重试一次
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _uploadOnce(
          bytes: bytes,
          filename: filename,
          mime: mime,
          expiry: expiry,
          onSendProgress: onSendProgress,
        );
      } on DioException catch (e) {
        final retryable = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout;
        if (retryable && attempt < 2) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        throw Exception(_friendlyError(e));
      }
    }
  }

  Future<RelavoUploadResult> _uploadOnce({
    required List<int> bytes,
    required String filename,
    required String mime,
    required String expiry,
    required void Function(int sent, int total) onSendProgress,
  }) async {
    try {
      final form = FormData.fromMap({
        'expiry': expiry,
        'files': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(mime),
        ),
      });
      final resp = await _dio.post(
        '/api/upload',
        data: form,
        onSendProgress: onSendProgress,
      );
      final data = resp.data;
      if (data is! Map) {
        throw const FormatException('服务器返回异常');
      }
      final imageUrls =
          (data['image_urls'] as List?)?.map((e) => e.toString()).toList() ??
              [];
      final urls =
          (data['urls'] as List?)?.map((e) => e.toString()).toList() ?? [];
      final direct = imageUrls.isNotEmpty
          ? imageUrls.first
          : (urls.isNotEmpty ? urls.first : '');
      if (direct.isEmpty) {
        throw const FormatException('服务器未返回图片链接');
      }
      final ids =
          (data['image_ids'] as List?)?.map((e) => e.toString()).toList() ??
              [];
      final tokens = (data['delete_tokens'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      return RelavoUploadResult(
        directUrl: direct,
        viewUrl: urls.isNotEmpty ? urls.first : null,
        imageId: ids.isNotEmpty ? ids.first : null,
        deleteToken: tokens.isNotEmpty ? tokens.first : null,
        expiresAt: data['expires_at']?.toString(),
      );
    } on DioException catch (e) {
      throw Exception(_friendlyError(e));
    }
  }

  Future<void> delete({required String imageId, required String token}) async {
    try {
      final form = FormData.fromMap({'image_id': imageId, 'token': token});
      final resp = await _dio.post('/api/delete', data: form);
      if (resp.statusCode != 200) {
        throw Exception('删除失败（${resp.statusCode}）');
      }
    } on DioException catch (e) {
      throw Exception(_friendlyError(e));
    }
  }

  String _friendlyError(DioException e) {
    final status = e.response?.statusCode;
    // 先看服务端是否给了具体原因
    final detail = e.response?.data;
    if (detail is Map && detail['detail'] != null) {
      return detail['detail'].toString();
    }
    if (status == 413) return '图片超过 10MB，请换一张更小的图片';
    if (status == 429) return '请求过于频繁，请稍后再试';
    if (status == 502 || status == 504) return '服务器暂时不可用，请稍后再试';
    if (status != null) {
      // 明确报出状态码，方便定位（例如 403、400、422）
      return '上传失败（服务器返回 $status），请重试';
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return '网络超时，请检查网络后重试';
    }
    if (e.type == DioExceptionType.connectionError) {
      final cause = e.error?.toString() ?? '';
      return cause.isEmpty ? '网络连接失败，请检查网络后重试' : '网络连接失败（$cause），请检查网络后重试';
    }
    if (e.type == DioExceptionType.badCertificate) {
      return '证书验证失败，请检查手机系统时间是否正确，然后重试';
    }
    final cause = e.error?.toString() ?? '';
    return cause.isEmpty ? '上传失败，请重试' : '上传失败（$cause），请重试';
  }
}
