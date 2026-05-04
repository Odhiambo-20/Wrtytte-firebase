import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:wrytte/components/user_avatar.dart';

class SnippItem extends StatelessWidget {
  final String profileImageUrl;
  final String displayName;
  final String username;
  final String caption;
  final VoidCallback? onComment;
  final VoidCallback? onLike;
  final VoidCallback? onShare;
  final VoidCallback? onSave;
  final VoidCallback? onFullVideo;
  final VoidCallback? onFollow;

  const SnippItem({
    super.key,
    this.profileImageUrl = "assets/images/user_avatar.png",
    this.displayName = "User",
    this.username = "User",
    this.caption = "",
    this.onComment,
    this.onLike,
    this.onShare,
    this.onSave,
    this.onFullVideo,
    this.onFollow,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background (placeholder for video)
        Container(
          color: Colors.black,
          child: const Center(
            child: Text(
              "Video Placeholder",
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ),
          ),
        ),

        // Foreground UI
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Left side: Profile info + caption
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                UserAvatar(size: 50, name: ''),
                                Positioned(
                                  bottom: -12,
                                  left: 13,
                                  child: GestureDetector(
                                    onTap: onFollow,
                                    child: Container(
                                      height: 25,
                                      width: 25,
                                      decoration: BoxDecoration(
                                        color: Color(0xFF4DA3FF),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.black,
                                          width: 2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.add,
                                        size: 20,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                                Text(
                                  "@$username",
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text(
                          caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Right side: Action buttons with counts
                Padding(
                  padding: const EdgeInsets.only(bottom: 115, right: 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _buildActionWithCountSvg(
                        'assets/svg/comment_icon.svg',
                        "120",
                        onComment,
                      ),
                      const SizedBox(height: 20),
                      _buildActionWithCount(Icons.favorite, "2.3K", onLike),
                      const SizedBox(height: 20),
                      _buildActionWithCount(
                        FontAwesomeIcons.share,
                        "56",
                        onShare,
                      ),
                      const SizedBox(height: 20),
                      _buildActionWithCountSvg(
                        'assets/svg/reward_icon.svg',
                        "98",
                        onSave,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // more_vert button
        Positioned(
          bottom: 90,
          right: 28,
          child: _buildActionButton(Icons.more_horiz, () {}),
        ),
      ],
    );
  }

  // Build icon + count vertically for regular IconData
  Widget _buildActionWithCount(
    IconData icon,
    String count,
    VoidCallback? onTap,
  ) {
    return Column(
      children: [
        _buildActionButton(icon, onTap),
        const SizedBox(height: 4),
        Text(count, style: const TextStyle(color: Colors.white, fontSize: 14)),
      ],
    );
  }

  // Build icon + count vertically for SVG icons
  Widget _buildActionWithCountSvg(
    String assetPath,
    String count,
    VoidCallback? onTap,
  ) {
    return Column(
      children: [
        _buildActionButtonSvg(assetPath, onTap),
        const SizedBox(height: 4),
        Text(count, style: const TextStyle(color: Colors.white, fontSize: 14)),
      ],
    );
  }

  // Basic icon button for regular IconData
  Widget _buildActionButton(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(icon, color: Colors.white, size: 30),
    );
  }

  // Basic icon button for SVG
  Widget _buildActionButtonSvg(String assetPath, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: SvgPicture.asset(
        assetPath,
        height: 25,
        width: 25,
        // ignore: deprecated_member_use
        color: Colors.white,
      ),
    );
  }
}
