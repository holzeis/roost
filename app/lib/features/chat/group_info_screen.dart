import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../profile/avatar_picker.dart';
import '../profile/avatar_viewer_screen.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';

/// FR1.4: who's actually in a group room, by name — the chat title only
/// ever showed a member *count* ("3 MEMBERS"), never who they are. Reached
/// by tapping the chat title in a group room (see chat_screen.dart's
/// _ChatTitle) — a 1:1 room has nothing this would add, since its one
/// other member is already named right there in the title.
///
/// Any member can change the group's picture from here by tapping it.
class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  bool _uploading = false;

  String get roomId => widget.roomId;

  void _showPictureOptions(String title, String? currentMediaId) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (currentMediaId != null)
              ListTile(
                leading: const Icon(TablerIcons.eye),
                title: const Text('View photo'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push(avatarViewerRoute(currentMediaId, title));
                },
              ),
            ListTile(
              leading: const Icon(TablerIcons.camera),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndUpload(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(TablerIcons.photo),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndUpload(ImageSource.gallery);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUpload(ImageSource source) async {
    setState(() => _uploading = true);
    try {
      final picked = await pickShrunkAvatar(ref, source);
      if (picked == null) return;
      await ref.read(apiClientProvider).uploadRoomAvatar(
            roomId,
            bytes: picked.bytes,
            filename: picked.filename,
            contentType: picked.contentType,
          );
      // The server also announces this to every member (room.updated), the
      // changer included; refreshing here just doesn't wait for that.
      ref.invalidate(roomProvider(roomId));
      await ref.read(roomsProvider.notifier).refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not change the picture: $error')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roomAsync = ref.watch(roomProvider(roomId));
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    final me = ref.watch(meProvider).valueOrNull;
    final scheme = Theme.of(context).colorScheme;

    final room = roomAsync.valueOrNull;
    final title = room?.name?.isNotEmpty == true ? room!.name! : 'Group info';

    return Scaffold(
      appBar: AppBar(leading: const TablerBackButton(), title: const Text('Group info')),
      body: room == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                  child: Column(
                    children: [
                      GestureDetector(
                        key: const ValueKey('group-avatar'),
                        onTap: _uploading
                            ? null
                            : () =>
                                _showPictureOptions(title, room.avatarMediaId),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (room.avatarMediaId != null && !_uploading)
                              InitialAvatar(
                                initial: title.isNotEmpty
                                    ? title[0].toUpperCase()
                                    : '?',
                                seed: title,
                                size: 72,
                                avatarMediaId: room.avatarMediaId,
                              )
                            else
                              Container(
                                width: 72,
                                height: 72,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.12),
                                  borderRadius:
                                      BorderRadius.circular(72 * 0.34),
                                ),
                                child: _uploading
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : Icon(TablerIcons.users,
                                        size: 34, color: scheme.primary),
                              ),
                            // Marks the picture as changeable.
                            Positioned(
                              right: -4,
                              bottom: -4,
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Theme.of(context)
                                          .scaffoldBackgroundColor,
                                      width: 2),
                                ),
                                child: Icon(TablerIcons.camera,
                                    size: 13, color: scheme.onPrimary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${room.members.length} members',
                        style: roostMono(context, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                  child: Text(
                    'MEMBERS',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: scheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                for (final memberId in room.members)
                  _MemberTile(
                    memberId: memberId,
                    isMe: memberId == me?.id,
                    contact: usersById[memberId],
                    myAvatarMediaId: me?.avatarMediaId,
                  ),
              ],
            ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.memberId,
    required this.isMe,
    required this.contact,
    required this.myAvatarMediaId,
  });

  final String memberId;
  final bool isMe;
  final ApiContact? contact;
  final String? myAvatarMediaId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = isMe ? 'You' : (contact?.displayName ?? '?');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: InitialAvatar(
        initial: name.isNotEmpty ? name[0].toUpperCase() : '?',
        seed: name,
        size: 44,
        // "You" are always online in your own view — presence for anyone
        // else comes from the same contacts list the Contacts screen uses.
        presenceOnline: isMe ? true : contact?.online,
        avatarMediaId: isMe ? myAvatarMediaId : contact?.avatarMediaId,
        viewable: true,
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: isMe
          ? null
          : Text(
              (contact?.online ?? false) ? 'Online' : 'Offline',
              style: TextStyle(
                color: (contact?.online ?? false)
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.45),
                fontSize: 13,
              ),
            ),
    );
  }
}
