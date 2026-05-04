import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wrytte/services/auth/auth_service.dart';
import 'package:wrytte/ui/screens/home_screen.dart';

class AddProfilePage extends StatefulWidget {
  const AddProfilePage({super.key});

  @override
  State<AddProfilePage> createState() => _AddProfilePageState();
}

class _AddProfilePageState extends State<AddProfilePage> {
  final TextEditingController _nicknameController = TextEditingController();
  bool _syncContacts = true;
  bool _isValid = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(_validate);
  }

  void _validate() {
    setState(() {
      _isValid = _nicknameController.text.trim().length >= 2;
    });
  }

  Future<void> _goHome() async {
    final uid = await AuthService.instance.getCurrentUserId();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => HomeScreen(currentUserId: uid ?? ''),
      ),
      (route) => false,
    );
  }

  Future<void> _saveAndGoHome() async {
    final name = _nicknameController.text.trim();
    if (name.length >= 2) {
      setState(() => _isSaving = true);
      try {
        final uid = await AuthService.instance.getCurrentUserId();
        if (uid != null && uid.isNotEmpty) {
          await FirebaseFirestore.instance.collection('users').doc(uid).set({
            'name': name,
            'username': name,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (e) {
        debugPrint('AddProfilePage save error: $e');
      } finally {
        if (mounted) setState(() => _isSaving = false);
      }
    }
    await _goHome();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : _goHome,  // ✅ Skip → HomeScreen
                    child: const Text(
                      "Skip",
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  TextButton(
                    onPressed: (_isValid && !_isSaving) ? _saveAndGoHome : null,
                    child: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            "Done",
                            style: TextStyle(
                              color: _isValid
                                  ? const Color(0xFF2AABEE)
                                  : Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ],
              ),

              const SizedBox(height: 40),

              GestureDetector(
                onTap: () {},
                child: const CircleAvatar(
                  radius: 50,
                  backgroundColor: Color(0xFF1F4F7F),
                  child: Icon(Icons.person, size: 50, color: Colors.white70),
                ),
              ),

              const SizedBox(height: 16),

              const Text(
                "Set profile photo",
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),

              const SizedBox(height: 40),

              TextField(
                controller: _nicknameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: "Enter Name",
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF23262C),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 18,
                  ),
                ),
              ),

              const SizedBox(height: 10),

              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Your name must include at least 2 letters or symbols",
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),

              const SizedBox(height: 30),

              Row(
                children: [
                  Checkbox(
                    value: _syncContacts,
                    activeColor: const Color(0xFF2AABEE),
                    onChanged: (value) {
                      setState(() => _syncContacts = value ?? true);
                    },
                  ),
                  const Text(
                    "Sync contacts",
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
