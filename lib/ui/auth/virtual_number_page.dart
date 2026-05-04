import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wrytte/services/auth/virtual_number_service.dart';
import 'package:wrytte/ui/auth/email_verification_page.dart';
import 'package:wrytte/ui/screens/terms_privacy_page.dart';

class VirtualNumberPage extends StatefulWidget {
  const VirtualNumberPage({super.key});

  @override
  State<VirtualNumberPage> createState() => _VirtualNumberPageState();
}

class _VirtualNumberPageState extends State<VirtualNumberPage> {
  final TextEditingController _emailCtrl = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  final VirtualNumberService _service = VirtualNumberService();

  bool _isLoading = false;
  bool _emailValid = false;
  bool _vpnLoading = true;

  String _virtualNumber = "";

  @override
  void initState() {
    super.initState();
    _fetchVpn();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  ///  STEP 1: Fetch VPN from backend
  Future<void> _fetchVpn() async {
    setState(() {
      _vpnLoading = true;
      _virtualNumber = ""; // clear old number while loading
    });

    try {
      final phone = await _service.getAvailableVpn();

      if (!mounted) return;

      setState(() {
        _virtualNumber = phone;
        _vpnLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() => _vpnLoading = false);

      debugPrint("Virtual number fetch error: $e");

      // Show user-friendly message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to fetch Wrytte ID number"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  ///  STEP 2: Validate email input
  void _validateEmail(String? value) {
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    setState(() {
      _emailValid = value != null && emailRegex.hasMatch(value.trim());
    });
  }

  ///  STEP 3: Send email verification code
  Future<void> _submit() async {
    if (!_emailValid || _isLoading || _virtualNumber.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      await _service.sendEmailCode(_emailCtrl.text.trim());

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => EmailVerificationPage(
                email: _emailCtrl.text.trim(),
                virtualNumber: _virtualNumber,
              ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to send verification email"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatVirtualNumber(String number) {
    if (number.length <= 2) return number;

    String first = number.substring(0, 2);
    String second =
        number.length > 5 ? number.substring(2, 5) : number.substring(2);
    String third =
        number.length > 8
            ? number.substring(5, 8)
            : (number.length > 5 ? number.substring(5) : "");
    String fourth = number.length > 8 ? number.substring(8) : "";

    return [first, second, third, fourth].where((e) => e.isNotEmpty).join(" ");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                24,
                16,
                24,
                MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ///  BACK
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),

                      const SizedBox(height: 16),

                      /// TITLE
                      const Center(
                        child: Text(
                          "Wrytte ID number",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),

                      const SizedBox(height: 8),

                      const Center(
                        child: Text(
                          "Please enter your Email.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.1,
                          ),
                        ),
                      ),

                      const SizedBox(height: 0),
                      Center(
                        child: GestureDetector(
                          onTap: _vpnLoading ? null : _fetchVpn,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Text(
                                "Choose another ",
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                "Wrytte ID number",
                                style: TextStyle(
                                  color: Color(0xFF4DA3FF),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 30),

                      /// INPUT CARD
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xFF23262C),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10, // <-- REDUCED from 14 to 10
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ///  VIRTUAL NUMBER (FROM BACKEND)
                            _vpnLoading
                                ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: 4,
                                    ), // <-- REDUCED from 8 to 4
                                    child: SizedBox(
                                      height:
                                          14, // <-- OPTIONAL: reduced from 16 to 14
                                      width:
                                          14, // <-- OPTIONAL: reduced from 16 to 14
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                )
                                : Text(
                                  "+${_formatVirtualNumber(_virtualNumber)}",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize:
                                        15, // <-- OPTIONAL: reduced from 16 to 15
                                    letterSpacing: 1.1,
                                  ),
                                ),

                            const SizedBox(
                              height: 8,
                            ), // <-- REDUCED from 12 to 8
                            const Divider(color: Colors.white24),

                            ///  EMAIL INPUT
                            TextField(
                              controller: _emailCtrl,
                              focusNode: _focusNode,
                              keyboardType: TextInputType.emailAddress,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize:
                                    15, // <-- OPTIONAL: reduced from default to 15
                              ),
                              inputFormatters: [
                                FilteringTextInputFormatter.deny(RegExp(r'\s')),
                              ],
                              decoration: const InputDecoration(
                                hintText: "Enter your email",
                                hintStyle: TextStyle(
                                  color: Colors.white54,
                                  fontSize:
                                      15, // <-- OPTIONAL: reduced from default to 15
                                ),
                                border: InputBorder.none,
                                isDense: true, // <-- ADD THIS for compact input
                              ),
                              onChanged: _validateEmail,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      /// Terms Text
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 15),
                        child: RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: const TextStyle(color: Colors.white),
                            children: [
                              const TextSpan(
                                text:
                                    "By entering your email and tapping “Next,” you agree to ",
                              ),
                              TextSpan(
                                text:
                                    "Wrytte’s Terms and Conditions and Privacy Policy",
                                style: const TextStyle(
                                  color: Color(0xFF4DA3FF),
                                ),
                                recognizer:
                                    TapGestureRecognizer()
                                      ..onTap = () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder:
                                                (_) => const TermsPrivacyPage(),
                                          ),
                                        );
                                      },
                              ),
                            ],
                          ),
                        ),
                      ),

                      const Spacer(),

                      /// NEXT BUTTON
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _emailValid && !_isLoading && !_vpnLoading
                                  ? _submit
                                  : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _emailValid
                                    ? const Color(0xFF4DA3FF)
                                    : const Color(0xFF23262C),
                            disabledBackgroundColor: const Color(0xFF23262C),
                            foregroundColor:
                                _emailValid ? Colors.white : Colors.grey,
                            disabledForegroundColor: Colors.grey,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child:
                              _isLoading
                                  ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                  : const Text(
                                    "Next",
                                    style: TextStyle(fontSize: 16),
                                  ),
                        ),
                      ),

                      const SizedBox(height: 50),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
