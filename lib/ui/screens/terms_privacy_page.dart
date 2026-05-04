import 'package:flutter/material.dart';

class TermsPrivacyPage extends StatelessWidget {
  const TermsPrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1013),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1013),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Column(
            children: [
              ///  LOGO + TITLE
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset("assets/images/wrytte_logo.png", height: 70),
                  const SizedBox(width: 4),
                  const Text(
                    "Wrytte Terms & Privacy",
                    style: TextStyle(
                      color: Color(0xFF4DA3FF),
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              ///  CONTENT
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      /// ---------------- TERMS & CONDITIONS ----------------
                      Text(
                        "Terms & Conditions",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      SizedBox(height: 12),

                      Text(
                        "1. Acceptance of Terms\n"
                        "By accessing or using Wrytte, you agree to comply with these Terms & Conditions. If you do not agree, please do not use the app.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "2. Account Registration\n"
                        "Wrytte allows registration using a phone number and a unique Wrytte ID number. You are responsible for maintaining the confidentiality of your account and login details.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "3. Messaging Services\n"
                        "Wrytte provides private messaging, public group messaging, channels, subscriptions, stories, and posts. Users must not send unlawful, harmful, abusive, or misleading content.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "4. Audio & Video Calls\n"
                        "Wrytte offers audio and video communication services. Users must comply with local laws when using these features.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "5. Channels & Subscriptions\n"
                        "Users may subscribe to channels and receive posts and updates. Channel owners are responsible for the content they publish.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "6. Marketplace (Shops)\n"
                        "Wrytte includes marketplace features that allow users to create shops and sell products. Wrytte is not responsible for disputes between buyers and sellers.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "7. User Profiles\n"
                        "Users may create public or private profiles. You are responsible for the accuracy of the information you provide.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "8. Prohibited Activities\n"
                        "You agree not to misuse the platform, attempt unauthorized access, distribute malware, or engage in fraudulent activity.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "9. Termination\n"
                        "Wrytte reserves the right to suspend or terminate accounts that violate these terms.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      SizedBox(height: 24),

                      /// ---------------- PRIVACY POLICY ----------------
                      Text(
                        "Privacy Policy",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      SizedBox(height: 12),

                      Text(
                        "1. Information We Collect\n"
                        "We collect information such as your phone number, Wrytte ID, profile details, messages, and usage data necessary to provide our services.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "2. Messaging Privacy\n"
                        "Private messages are intended only for the sender and recipient. We implement reasonable security measures to protect communications.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "3. Calls & Media\n"
                        "Audio and video calls may transmit data over secure networks. We do not publicly share call content.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "4. Marketplace Data\n"
                        "Shop information, listings, and transactions may be stored to facilitate marketplace services.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "5. Data Security\n"
                        "We apply technical and organizational safeguards to protect user information against unauthorized access.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "6. Data Sharing\n"
                        "We do not sell your personal information. Data may be shared only where legally required or to provide core services.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "7. User Rights\n"
                        "Users may update or delete their accounts and request access to their data subject to applicable laws.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      Text(
                        "8. Updates to Policy\n"
                        "Wrytte may update these Terms & Privacy policies periodically. Continued use of the app constitutes acceptance of changes.\n",
                        style: TextStyle(color: Colors.white70, height: 1.6),
                      ),

                      SizedBox(height: 20),

                      Text(
                        "Last Updated: 2026",
                        style: TextStyle(color: Colors.white38),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
