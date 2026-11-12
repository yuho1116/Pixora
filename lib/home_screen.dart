import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exif.dart';
import 'models.dart';
import 'relavo_api.dart';
import 'settings_screen.dart';
import 'viewer_screen.dart';

/// 首页：上传工作台。打开应用直接进入，无需注册登录。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _maxFiles = 10;
  static const int _maxBytes = 10 * 1024 * 1024;
  static const Set<String> _allowedExt = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
  };
  static const Map<String, String> _mimeByExt = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  final RelavoApi _api = RelavoApi();
  final List<UploadItem> _items = [];
  String _expiry = '24h';
  bool _uploading = false;
  bool _dragging = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadExpiry();
  }

  Future<void> _loadExpiry() async {
    final v = await loadExpiry();
    if (mounted) setState(() => _expiry = v);
  }

  Future<void> _changeExpiry(String v) async {
    await saveExpiry(v);
    if (mounted) setState(() => _expiry = v);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ---------- 选择 / 拖放 ----------

  Future<void> _pickFiles() async {
    if (_uploading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
      // 关键修复：file_picker 默认 allowCompression=true，Android 上选图后
      // 会把每张图压缩成 JPEG_时间戳.jpg 写到公共 Pictures 目录，相册里
      // 就会多出一张，还会把原图压成 30% 画质的 JPEG。关闭后只读原图，
      // 不在手机上产生任何新文件，上传的也是原画质。
      allowCompression: false,
    );
    if (result == null) return;
    final picked = <({String name, Uint8List bytes})>[];
    for (final f in result.files) {
      Uint8List? bytes = f.bytes;
      bytes ??= f.path != null ? await File(f.path!).readAsBytes() : null;
      if (bytes != null) picked.add((name: f.name, bytes: bytes));
    }
    // 字节已读进内存，清理 file_picker 在应用私有缓存里留下的临时副本，
    // 不让缓存越积越多。私有缓存本身不会出现在相册，这里只是顺手清理。
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (_) {
      // 清理失败不影响上传
    }
    _addPicked(picked);
  }

  void _onDrop(DropDoneDetails details) async {
    if (_uploading) return;
    setState(() => _dragging = false);
    final picked = <({String name, Uint8List bytes})>[];
    for (final XFile f in details.files) {
      try {
        picked.add((name: f.name, bytes: await f.readAsBytes()));
      } catch (_) {
        // 单个文件读取失败时跳过，不影响其他文件
      }
    }
    _addPicked(picked);
  }

  void _addPicked(List<({String name, Uint8List bytes})> picked) {
    if (picked.isEmpty) return;
    final rejected = <String>[];
    var added = 0;
    for (final p in picked) {
      final ext = p.name.split('.').last.toLowerCase();
      if (!_allowedExt.contains(ext)) {
        rejected.add('${p.name}：仅支持 JPG、PNG、WebP、GIF');
        continue;
      }
      if (p.bytes.length > _maxBytes) {
        rejected.add('${p.name}：单张图片最大 10MB');
        continue;
      }
      if (_items.length >= _maxFiles) {
        rejected.add('单次最多上传 $_maxFiles 张图片');
        break;
      }
      final mime = _mimeByExt[ext]!;
      final clean = stripMetadata(p.bytes, mime);
      _items.add(UploadItem(
        id: 'local-${DateTime.now().millisecondsSinceEpoch}-${_seq++}',
        name: p.name,
        mime: mime,
        bytes: clean,
        thumbBytes: makeThumbnail(clean),
      ));
      added++;
    }
    setState(() {});
    if (rejected.isNotEmpty) {
      _snack(rejected.first);
    } else if (added > 0) {
      // 已加入列表，无需打扰用户
    }
  }

  // ---------- 上传 ----------

  List<UploadItem> get _todoItems =>
      _items.where((i) => i.status != UploadStatus.done).toList();

  List<UploadItem> get _doneItems =>
      _items.where((i) => i.status == UploadStatus.done).toList();

  Future<bool> _uploadOne(UploadItem item) async {
    setState(() {
      item.status = UploadStatus.uploading;
      item.progress = 0;
      item.error = null;
    });
    try {
      final result = await _api.upload(
        bytes: item.bytes,
        filename: item.name,
        mime: item.mime,
        expiry: _expiry,
        onSendProgress: (sent, total) {
          if (total > 0 && mounted) {
            setState(() => item.progress = sent / total);
          }
        },
      );
      setState(() {
        item.status = UploadStatus.done;
        item.progress = 1;
        item.url = result.directUrl;
        item.viewUrl = result.viewUrl;
        item.imageId = result.imageId;
        item.deleteToken = result.deleteToken;
        item.expiresAt = result.expiresAt;
      });
      return true;
    } catch (e) {
      setState(() {
        item.status = UploadStatus.error;
        item.error = e.toString().replaceFirst('Exception: ', '');
      });
      return false;
    }
  }

  Future<void> _uploadAll() async {
    if (_uploading || _todoItems.isEmpty) return;
    setState(() => _uploading = true);
    var ok = 0;
    var fail = 0;
    for (final item in List.of(_todoItems)) {
      if (await _uploadOne(item)) {
        ok++;
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    if (fail == 0) {
      _snack(ok == 1 ? '上传完成' : '全部上传完成');
    } else {
      _snack('$ok 张成功，$fail 张失败，可点击重试');
    }
  }

  // ---------- 复制 / 查看 / 删除 ----------

  Future<void> _copyText(String text, {String tip = '链接已复制'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    _snack(tip);
  }

  void _copyAll() {
    final urls =
        _doneItems.map((i) => i.url).whereType<String>().toList();
    if (urls.isEmpty) return;
    _copyText(urls.join('\n'), tip: '全部链接已复制');
  }

  Future<void> _deleteUploaded(UploadItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('删除图片'),
        content: const Text('确定要删除这张图片吗？删除后链接立即失效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (item.imageId == null || item.deleteToken == null) {
      setState(() => _items.remove(item));
      return;
    }
    try {
      await _api.delete(imageId: item.imageId!, token: item.deleteToken!);
      setState(() => _items.remove(item));
      _snack('已删除');
    } catch (e) {
      _snack('删除失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    _loadExpiry();
  }

  // ---------- 界面 ----------

  static const _ink = Color(0xFF111827);
  static const _sub = Color(0xFF6B7280);
  static const _line = Color(0xFFEDEDEF);
  static const _soft = Color(0xFFF7F7F9);

  @override
  Widget build(BuildContext context) {
    final hasTodo = _todoItems.isNotEmpty;
    final hasDone = _doneItems.isNotEmpty;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 28),
                const Text(
                  '让图片分享更简单',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '上传图片，生成链接，随时分享。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: _sub),
                ),
                const SizedBox(height: 24),
                _buildDropZone(),
                const SizedBox(height: 14),
                _buildExpiryRow(),
                if (hasTodo) ...[
                  const SizedBox(height: 22),
                  _buildSectionTitle('图片列表（${_items.length}）'),
                  const SizedBox(height: 10),
                  ..._todoItems.map(_buildTodoCard),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _uploading ? null : _uploadAll,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _ink,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFFD1D5DB),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        _uploading ? '上传中…' : '开始上传',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
                if (hasDone) ...[
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      const Expanded(child: _SectionTitle('上传完成')),
                      TextButton.icon(
                        onPressed: _copyAll,
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: const Text('复制全部链接'),
                        style: TextButton.styleFrom(
                          foregroundColor: _ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ..._doneItems.map(_buildDoneCard),
                ],
                const SizedBox(height: 28),
                const Text(
                  '图片仅通过链接访问 · EXIF 与位置信息会在上传时自动清除',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: _sub),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.image_outlined, color: Colors.white),
        ),
        const SizedBox(width: 10),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pixora',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: _ink,
              ),
            ),
            Text(
              '上传 · 分享 · 简单完成',
              style: TextStyle(fontSize: 11, color: _sub),
            ),
          ],
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: _ink),
          tooltip: '设置',
          onPressed: _openSettings,
        ),
      ],
    );
  }

  Widget _buildDropZone() {
    return GestureDetector(
      onTap: _pickFiles,
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _onDrop,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
          decoration: BoxDecoration(
            color: _dragging ? const Color(0xFFF0F0F2) : _soft,
            border: Border.all(
              color: _dragging ? _ink : const Color(0xFFE5E7EB),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              const Icon(Icons.cloud_upload_outlined,
                  size: 44, color: Color(0xFF9CA3AF)),
              const SizedBox(height: 12),
              const Text(
                '将图片拖放到这里',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 6),
              const Text('选择图片，快速生成可分享链接',
                  style: TextStyle(color: _sub)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _pickFiles,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _ink,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(160, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('选择图片', style: TextStyle(fontSize: 15)),
              ),
              const SizedBox(height: 12),
              const Text(
                '支持 JPG、PNG、WebP、GIF，单张最大 10MB',
                style: TextStyle(fontSize: 12, color: _sub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpiryRow() {
    return Row(
      children: [
        const Text('保存时间', style: TextStyle(color: _sub, fontSize: 14)),
        const Spacer(),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _expiry,
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            style: const TextStyle(fontSize: 14, color: _ink),
            items: expiryLabels.entries
                .map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) _changeExpiry(v);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return _SectionTitle(title);
  }

  Widget _buildTodoCard(UploadItem item) {
    final statusText = switch (item.status) {
      UploadStatus.pending => '待上传',
      UploadStatus.uploading =>
        '上传中 ${(item.progress * 100).round()}%',
      UploadStatus.done => '已完成',
      UploadStatus.error => '上传失败：${item.error ?? '请重试'}',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  item.thumbBytes,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 56,
                    height: 56,
                    color: _soft,
                    child: const Icon(Icons.image_outlined,
                        color: Color(0xFF9CA3AF)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatSize(item.size)} · $statusText',
                      style: TextStyle(
                        fontSize: 12,
                        color: item.status == UploadStatus.error
                            ? const Color(0xFFDC2626)
                            : _sub,
                      ),
                    ),
                  ],
                ),
              ),
              if (item.status == UploadStatus.error)
                TextButton(
                  onPressed: () => _uploadOne(item),
                  child: const Text('重试'),
                )
              else if (item.status != UploadStatus.uploading)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: _sub,
                  tooltip: '删除',
                  onPressed: () => setState(() => _items.remove(item)),
                ),
            ],
          ),
          if (item.status == UploadStatus.uploading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: item.progress == 0 ? null : item.progress,
                backgroundColor: const Color(0xFFEDEDEF),
                color: _ink,
                minHeight: 4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDoneCard(UploadItem item) {
    final url = item.url ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  item.thumbBytes,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 56,
                    height: 56,
                    color: _soft,
                    child: const Icon(Icons.image_outlined,
                        color: Color(0xFF9CA3AF)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatSize(item.size)} · 已完成',
                      style: const TextStyle(fontSize: 12, color: _sub),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: _sub,
                tooltip: '删除图片',
                onPressed: () => _deleteUploaded(item),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _soft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF2563EB)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _copyText(url),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _ink,
                    side: const BorderSide(color: Color(0xFFE5E7EB)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('复制链接'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ViewerScreen(url: url, name: item.name),
                      ),
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _ink,
                    side: const BorderSide(color: Color(0xFFE5E7EB)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('查看图片'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Color(0xFF111827),
      ),
    );
  }
}
