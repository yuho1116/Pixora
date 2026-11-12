import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

const String _prefsKey = 'pixora_expiry';

/// 读取保存的保存期限，默认 24 小时。
Future<String> loadExpiry() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_prefsKey) ?? '24h';
}

Future<void> saveExpiry(String value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey, value);
}

/// 设置页：只保留必要选项——保存时间、隐私说明、版本、关于。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _expiry = '24h';

  @override
  void initState() {
    super.initState();
    loadExpiry().then((v) {
      if (mounted) setState(() => _expiry = v);
    });
  }

  Future<void> _pick(String value) async {
    await saveExpiry(value);
    if (mounted) setState(() => _expiry = value);
  }

  void _showAbout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('关于 Pixora'),
        content: const Text(
          'Pixora 是一款轻量级图片上传与链接分享工具，帮助用户将图片转换为链接，方便在聊天、社区、论坛和日常工作中分享。\n\n上传 · 分享 · 简单完成\n\n无需注册，打开即可使用。',
          style: TextStyle(height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                '图片保存时间',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFEDEDEF)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: expiryLabels.entries.map((entry) {
                    return RadioListTile<String>(
                      value: entry.key,
                      groupValue: _expiry,
                      activeColor: const Color(0xFF111827),
                      title: Text(entry.value),
                      subtitle: Text(expiryHints[entry.key] ?? ''),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      onChanged: (v) {
                        if (v != null) _pick(v);
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '隐私',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F7F9),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 20, color: Color(0xFF6B7280)),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '图片隐私处理\n上传时会自动清除 EXIF、GPS、相机型号等隐私元数据；图片仅通过链接访问，不会公开列出。',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.7,
                          color: Color(0xFF374151),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '关于',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFEDEDEF)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('软件版本'),
                      trailing: const Text(
                        'Pixora 1.0.0',
                        style: TextStyle(color: Color(0xFF6B7280)),
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFF0F0F2)),
                    ListTile(
                      title: const Text('关于 Pixora'),
                      trailing: const Icon(Icons.chevron_right,
                          color: Color(0xFF9CA3AF)),
                      onTap: _showAbout,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
