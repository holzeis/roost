import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create(List<ApiContact> contacts) async {
    setState(() => _creating = true);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final room = await ref.read(roomsProvider.notifier).createRoom(
            name: _nameController.text.trim().isEmpty ? null : _nameController.text.trim(),
            isGroup: true,
            memberIds: _selected.toList(),
          );
      if (!mounted) return;
      router.pop();
      router.push('/chat/${room.id}');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create group: $error')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: const Text('New group'),
        actions: [
          users.when(
            data: (contacts) => TextButton(
              onPressed: (_selected.isEmpty || _creating) ? null : () => _create(contacts),
              child: _creating
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create'),
            ),
            error: (_, __) => const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: users.when(
        error: (error, _) => Center(child: Text('Could not load contacts.\n$error')),
        loading: () => const Center(child: CircularProgressIndicator()),
        data: (contacts) {
          final scheme = Theme.of(context).colorScheme;
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: scheme.onSurface.withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.group_outlined, color: scheme.onSurface.withOpacity(0.5)),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: scheme.primary,
                            child: const Icon(Icons.camera_alt_outlined, size: 11, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: TextField(
                        controller: _nameController,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        decoration: InputDecoration(
                          hintText: 'Group name',
                          filled: true,
                          fillColor: scheme.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: scheme.onSurface.withOpacity(0.1)),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final id in _selected)
                        Builder(builder: (context) {
                          final contact = contacts.firstWhere((c) => c.id == id);
                          return Chip(
                            avatar: InitialAvatar(
                              initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
                              seed: contact.displayName,
                              size: 20,
                            ),
                            label: Text(contact.displayName),
                            visualDensity: VisualDensity.compact,
                          );
                        }),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                child: Text(
                  'ADD PEOPLE',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: scheme.onSurface.withOpacity(0.45),
                  ),
                ),
              ),
              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nobody else has connected yet.',
                    style: TextStyle(color: scheme.onSurface.withOpacity(0.55)),
                  ),
                ),
              for (final contact in contacts)
                CheckboxListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
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
