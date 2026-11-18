import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/network/bili_client.dart';
import '../services/bili_api.dart';

/// Optional Bilibili login, accessible only from Settings.
class TingXSettings extends StatefulWidget {
  const TingXSettings({super.key});
  @override
  State<TingXSettings> createState() => _TingXSettingsState();
}

class _TingXSettingsState extends State<TingXSettings> {
  bool busy = true;
  bool loggedIn = false;
  String userName = '';
  String? error;

  @override
  void initState() {
    super.initState();
    checkAccount();
  }

  Future<void> checkAccount() async {
    setState(() { busy = true; error = null; });
    try {
      final user = await BiliApi.instance.currentUser();
      if (!mounted) return;
      setState(() { loggedIn = user.isLogin; userName = user.uname; });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loggedIn = BiliClient.instance.isLoggedIn;
        error = '无法验证登录状态，请检查网络';
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('退出 B站账号？'),
        content: const Text('只清除本机登录信息，不影响 TingX 本地书架。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok != true) return;
    await BiliClient.instance.logout();
    if (mounted) setState(() { loggedIn = false; userName = ''; error = null; });
  }

  Future<void> signIn() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const _QrLogin()),
    );
    if (mounted) await checkAccount();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: ListView(children: [
      const ListTile(
        title: Text('播放与书架'),
        subtitle: Text('在线收听 · 进度仅保存在本机'),
      ),
      const Divider(),
      ListTile(
        title: const Text('B站账号'),
        subtitle: Text(busy ? '检查中…' : loggedIn
            ? (userName.isEmpty ? '已登录' : '已登录 · $userName')
            : '游客模式 · 登录完全可选'),
        trailing: const Icon(Icons.chevron_right),
        onTap: busy ? null : loggedIn ? signOut : signIn,
      ),
      if (error != null)
        Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
      const Padding(
        padding: EdgeInsets.all(20),
        child: Text('TingX 不提供独立账号、下载或分享功能。登录仅用于访问 B站允许该账号访问的内容。',
          style: TextStyle(color: Colors.grey, fontSize: 12)),
      ),
    ]),
  );
}

class _QrLogin extends StatefulWidget {
  const _QrLogin();
  @override
  State<_QrLogin> createState() => _QrLoginState();
}

class _QrLoginState extends State<_QrLogin> {
  String? url;
  String? key;
  String status = '正在获取二维码…';
  Timer? timer;
  bool polling = false;

  @override
  void initState() {
    super.initState();
    generate();
  }

  Future<void> generate() async {
    timer?.cancel();
    setState(() { url = null; key = null; status = '正在获取二维码…'; });
    try {
      final qr = await BiliApi.instance.qrGenerate();
      if (!mounted) return;
      if (qr.url.isEmpty || qr.qrKey.isEmpty) throw StateError('二维码为空');
      setState(() { url = qr.url; key = qr.qrKey; status = '使用 B站 App 扫码登录'; });
      timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
    } catch (_) {
      if (mounted) setState(() => status = '二维码获取失败，请重试');
    }
  }

  Future<void> poll() async {
    if (polling || key == null || !mounted) return;
    polling = true;
    try {
      final state = await BiliApi.instance.qrPoll(key!);
      if (!mounted) return;
      if (state == 'success') {
        timer?.cancel();
        Navigator.pop(context);
      } else if (state == 'expired') {
        timer?.cancel();
        setState(() => status = '二维码已过期，请刷新');
      } else if (state == 'scanned') {
        setState(() => status = '已扫码，请在 B站 App 中确认');
      } else if (state == 'fail') {
        timer?.cancel();
        setState(() => status = '登录失败，请重新获取二维码');
      }
    } catch (_) {
      if (mounted) setState(() => status = '网络异常，等待重试');
    } finally {
      polling = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('登录 B站')),
    body: Center(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (url != null)
          QrImageView(data: url!, size: 220, backgroundColor: Colors.white)
        else SizedBox(
          height: 220,
          child: Center(
            child: status == '正在获取二维码…'
                ? const CircularProgressIndicator()
                : const Icon(Icons.qr_code_2, size: 96, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 20),
        Text(status),
        const SizedBox(height: 16),
        TextButton(onPressed: generate, child: const Text('刷新二维码')),
        const Text('登录完全可选，退出后仍可使用本地书架',
          style: TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    )),
  );
}
