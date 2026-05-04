import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class UserAvatar extends StatelessWidget {
  final double size;
  final ImageProvider? image;
  final String? imageUrl;
  final String? name;
  final VoidCallback? onTap;
  final String? heroTag;

  const UserAvatar({
    super.key,
    this.size = 40.0,
    this.image,
    this.imageUrl,
    this.name,
    this.onTap,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    Widget avatarWidget;

    if (image != null) {
      avatarWidget = _buildFromImageProvider(image!);
    } else if (imageUrl != null && imageUrl!.isNotEmpty) {
      avatarWidget = ClipOval(
        child: CachedNetworkImage(
          imageUrl: imageUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (context, url) => _buildPlaceholder(),
          errorWidget: (context, url, error) => _buildPlaceholder(),
        ),
      );
    } else {
      avatarWidget = _buildPlaceholder();
    }

    final wrapped = GestureDetector(
      onTap: onTap,
      child: SizedBox(width: size, height: size, child: avatarWidget),
    );

    return heroTag != null ? Hero(tag: heroTag!, child: wrapped) : wrapped;
  }

  Widget _buildFromImageProvider(ImageProvider provider) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        image: DecorationImage(image: provider, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildPlaceholder() {
    // Show initials if name is available, otherwise icon
    final initials = _getInitials(name);

    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF0F2A44),
      ),
      child: Center(
        child:
            initials != null
                ? Text(
                  initials,
                  style: TextStyle(
                    color: const Color(0xFF4DA3FF),
                    fontSize: size * 0.36,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                )
                : Icon(
                  Icons.person,
                  size: size * 0.5,
                  color: const Color(0xFF4DA3FF),
                ),
      ),
    );
  }

  /// Returns up to 2 initials from the name, or null if name is empty.
  String? _getInitials(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}
