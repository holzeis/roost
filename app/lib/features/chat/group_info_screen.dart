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
/// Any member can change the group's picture or name, add people, mute it
/// for themselves, leave it and (if they created it) delete it from here.
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

  /// Runs [action] and then refreshes this room; shows [failure] and the
  /// error if it throws.
  Future<void> _change(String failure, Future<void> Function() action) async {
    try {
      await action();
      await ref.read(roomsProvider.notifier).roomChanged(roomId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failure: $error')));
      }
    }
  }

  Future<void> _rename(String currentName) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(currentName: currentName),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == currentName) return;
    await _change('Could not rename the group', () => ref.read(apiClientProvider).renameRoom(roomId, trimmed));
  }

  void _showMuteOptions(ApiRoom room) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        Widget option(String label, RoomMuteDuration duration) => ListTile(
              title: Text(label),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _change('Could not mute the group', () => ref.read(apiClientProvider).muteRoom(roomId, duration));
              },
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Mute notifications', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
              option('For 8 hours', RoomMuteDuration.eightHours),
              option('For 1 week', RoomMuteDuration.oneWeek),
              option('Always', RoomMuteDuration.always),
              if (room.muted)
                ListTile(
                  title: const Text('Unmute'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _change('Could not unmute the group', () => ref.read(apiClientProvider).unmuteRoom(roomId));
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _leave(String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Leave "$title"?'),
        content: const Text('You will no longer get its messages. Someone in the group can add you back.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).leaveRoom(roomId);
      await ref.read(roomsProvider.notifier).refresh();
      router.go('/');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not leave the group: $error')));
    }
  }

  Future<void> _delete(String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "$title"?'),
        content: const Text('The group and all its messages and photos are deleted for everyone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).deleteRoom(roomId);
      await ref.read(roomsProvider.notifier).refresh();
      router.go('/');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not delete the group: $error')));
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
                      GestureDetector(
                        key: const ValueKey('group-name'),
                        onTap: () => _rename(room.name ?? ''),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(TablerIcons.pencil, size: 16, color: scheme.onSurface.withValues(alpha: 0.45)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${room.members.length} members',
                        style: roostMono(context, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  key: const ValueKey('group-mute'),
                  leading: Icon(room.muted ? TablerIcons.bellOff : TablerIcons.bell),
                  title: const Text('Mute notifications'),
                  subtitle: Text(muteLabel(context, room)),
                  onTap: () => _showMuteOptions(room),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
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
                ListTile(
                  key: const ValueKey('group-add-members'),
                  leading: CircleAvatar(
                    backgroundColor: scheme.primary.withValues(alpha: 0.12),
                    child: Icon(TablerIcons.userPlus, color: scheme.primary),
                  ),
                  title: const Text('Add people', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  onTap: () => context.push('/chat/$roomId/add-members'),
                ),
                for (final memberId in room.members)
                  _MemberTile(
                    memberId: memberId,
                    isMe: memberId == me?.id,
                    contact: usersById[memberId],
                    myAvatarMediaId: me?.avatarMediaId,
                  ),
                const Divider(height: 24),
                ListTile(
                  key: const ValueKey('group-leave'),
                  leading: Icon(TablerIcons.logout, color: scheme.error),
                  title: Text('Leave group', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                  onTap: () => _leave(title),
                ),
                // Only the person who created the group can delete it.
                if (room.createdBy == me?.id)
                  ListTile(
                    key: const ValueKey('group-delete'),
                    leading: Icon(TablerIcons.trash, color: scheme.error),
                    title: Text('Delete group', style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                    onTap: () => _delete(title),
                  ),
              ],
            ),
    );
  }
}

/// Asks for a group's new name; pops with what was typed (or null).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.currentName});

  final String currentName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.currentName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Group name'),
      content: TextField(
        key: const ValueKey('group-name-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 100,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(_controller.text), child: const Text('Save')),
      ],
    );
  }
}

/// What the mute row says: whether the group's notifications are muted, and
/// until when.
String muteLabel(BuildContext context, ApiRoom room, {DateTime? now}) {
  if (!room.muted) return 'Off';
  final until = room.mutedUntil?.toLocal();
  if (until == null) return 'Muted';
  final l10n = MaterialLocalizations.of(context);
  final time = l10n.formatTimeOfDay(TimeOfDay.fromDateTime(until));
  final today = now ?? DateTime.now();
  final sameDay = until.year == today.year && until.month == today.month && until.day == today.day;
  return sameDay ? 'Muted until $time' : 'Muted until ${l10n.formatMediumDate(until)}, $time';
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
