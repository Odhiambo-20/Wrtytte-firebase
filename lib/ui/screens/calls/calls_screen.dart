import 'package:flutter/material.dart';

class CallsScreen extends StatelessWidget {
  const CallsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No recent calls',
        style: TextStyle(color: Colors.white54, fontSize: 15),
      ),
    );
  }
}
