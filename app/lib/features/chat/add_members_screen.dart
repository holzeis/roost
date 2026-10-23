import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

/// Any member of a group can add more people to it: this lists everyone who
/// isn't in the group yet. Reached from group info.
class AddMembersScreen extends ConsumerStatefulWidget {
  const AddMembersScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<AddMembersScreen> createState() => _AddMembersScreenState();
}

class _AddMembersScreenState extends ConsumerState<AddMembersScreen> {
  final _selected = <String>{};
  bool _adding = false;

  Future<void> _add() async {
    setState(() => _adding = true);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(apiClientProvider).addRoomMembers(widget.roomId, _selected.toList());
      await ref.read(roomsProvider.notifier).roomChanged(widget.roomId);
      if (!mounted) return;
      router.pop();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not add people: $error')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersProvider);
    final room = ref.watch(roomProvider(widget.roomId)).valueOrNull;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(TablerIcons.x), onPressed: () => Navigator.of(context).pop()),
        title: const Text('Add people'),
        actions: [
          TextButton(
            onPressed: (_selected.isEmpty || _adding) ? null : _add,
            child: _adding
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Add'),
          ),
        ],
      ),
      body: users.when(
        error: (error, _) => Center(child: Text('Could not load contacts.\n$error')),
        loading: () => const Center(child: CircularProgressIndicator()),
        data: (contacts) {
          if (room == null) return const Center(child: CircularProgressIndicator());
          final candidates = contacts.where((c) => !room.members.contains(c.id)).toList();
          if (candidates.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Everyone is already in this group.',
                  style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55)),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final contact in candidates)
                CheckboxListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  value: _selected.contains(contact.id),
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      _selected.add(contact.id);
                    } else {
                      _selected.remove(contact.id);
                    }
                  }),
                  secondary: InitialAvatar(
                    initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
                    seed: contact.displayName,
                    size: 44,
                    avatarMediaId: contact.avatarMediaId,
                  ),
                  title: Text(contact.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ],
          );
        },
      ),
    );
  }
}
