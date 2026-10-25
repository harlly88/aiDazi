import 'package:flutter/material.dart';

import 'i18n.dart';
import 'storage.dart';

/// 我的设定（15.9：用户画像）
///
/// 称呼/职业/年龄/其他 → prompt 注入（utils.dart buildContextInjections）；
/// 称呼非空时替换 {{user}} 宏取值来源（storage.getUserName）。
/// 26.1-4/5：生日与位置感知开关已删除（隐私收敛）。
class UserProfilePage extends StatefulWidget {
  const UserProfilePage({super.key});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  final _nameController = TextEditingController();
  final _occupationController = TextEditingController();
  final _ageController = TextEditingController();
  final _otherController = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await getUserProfile();
    if (!mounted) return;
    setState(() {
      _nameController.text = profile.name;
      _occupationController.text = profile.occupation;
      _ageController.text = profile.age;
      _otherController.text = profile.other;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _occupationController.dispose();
    _ageController.dispose();
    _otherController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await setUserProfile(UserProfile(
      name: _nameController.text.trim(),
      occupation: _occupationController.text.trim(),
      age: _ageController.text.trim(),
      other: _otherController.text.trim(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(I18n.t('profile_saved'))),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(I18n.t('my_profile')),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: I18n.t('confirm'),
            onPressed: _save,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                Text(
                  I18n.t('my_profile_hint'),
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: I18n.t('profile_nickname'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _occupationController,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: I18n.t('profile_occupation'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _ageController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: I18n.t('profile_age'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _otherController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: I18n.t('profile_other'),
                  ),
                ),
              ],
            ),
    );
  }
}
