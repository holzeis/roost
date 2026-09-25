import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';

/// FR1.4: who's actually in a group room, by name — the chat title only
/// ever showed a member *count* ("3 MEMBERS"), never who they are. Reached
/// by tapping the chat title in a group room (see chat_screen.dart's
/// _ChatTitle) — a 1:1 room has nothing this would add, since its one
/// other member is already named right there in the title.
class GroupInfoScreen extends ConsumerWidget {
  const GroupInfoScreen({super.key, required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                      Container(
                        width: 72,
                        height: 72,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(72 * 0.34),
                        ),
                        child: Icon(TablerIcons.users, size: 34, color: scheme.primary),
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
