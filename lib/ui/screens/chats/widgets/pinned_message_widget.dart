import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PinnedMessageWidget extends StatelessWidget {
  final DocumentSnapshot? pinnedMessageDoc;
  final VoidCallback onTap;
  final String currentUserId;
  final String otherUserName;

  const PinnedMessageWidget({
    super.key,
    required this.pinnedMessageDoc,
    required this.onTap,
    required this.currentUserId,
    required this.otherUserName,
  });

  String _getMessagePreview(Map<String, dynamic> messageData) {
    final messageType = messageData['messageType'] ?? 'text';

    if (messageType == 'text') {
      final text = messageData['text'] ?? '';
      return text.length > 40 ? '${text.substring(0, 40)}...' : text;
    } else if (messageType == 'image') {
      return '📷 Photo';
    } else if (messageType == 'audio') {
      return '🎤 Voice message';
    }

    return 'Unknown message type';
  }

  String _getSenderName(Map<String, dynamic> messageData) {
    final senderId = messageData['senderId'] ?? '';
    return senderId == currentUserId ? 'You' : otherUserName;
  }

  @override
  Widget build(BuildContext context) {
    if (pinnedMessageDoc == null || !pinnedMessageDoc!.exists) {
      return const SizedBox.shrink();
    }

    final messageData = pinnedMessageDoc!.data() as Map<String, dynamic>;
    final senderName = _getSenderName(messageData);
    final messagePreview = _getMessagePreview(messageData);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade800, width: 1),
        ),
        child: Row(
          children: [
            // Pin icon
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.push_pin, color: Colors.blue, size: 16),
            ),

            const SizedBox(width: 12),

            // Message preview
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Pinned message',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '$senderName: ',
                          style: const TextStyle(
                            color: Colors.blue,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextSpan(
                          text: messagePreview,
                          style: TextStyle(
                            color: Colors.grey.shade300,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Close/Unpin button (optional - can be added later)
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
