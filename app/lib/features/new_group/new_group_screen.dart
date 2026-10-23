import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../services/image_shrinker.dart';
import '../profile/avatar_picker.dart';
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

  /// The picture picked for the group, uploaded once the group exists.
  ShrunkImage? _picture;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _showPictureOptions() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(TablerIcons.camera),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pick(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(TablerIcons.photo),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pick(ImageSource.gallery);
              },
            ),
            if (_picture != null)
              ListTile(
                leading: const Icon(TablerIcons.trash),
                title: const Text('Remove photo'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  setState(() => _picture = null);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await pickShrunkAvatar(ref, source);
      if (picked != null && mounted) setState(() => _picture = picked);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not use that picture: $error')));
      }
    }
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
      // The group exists either way: a picture that fails to upload can be
      // set again from group info.
      final picture = _picture;
      if (picture != null) {
        try {
          await ref.read(apiClientProvider).uploadRoomAvatar(
                room.id,
                bytes: picture.bytes,
                filename: picture.filename,
                contentType: picture.contentType,
              );
          await ref.read(roomsProvider.notifier).refresh();
        } catch (error) {
          messenger.showSnackBar(SnackBar(content: Text('Group created, but the picture could not be set: $error')));
        }
      }
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
        leading: IconButton(icon: const Icon(TablerIcons.x), onPressed: () => Navigator.of(context).pop()),
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
                    GestureDetector(
                      key: const ValueKey('new-group-avatar'),
                      onTap: _creating ? null : _showPictureOptions,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: scheme.onSurface.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: _picture == null
                                ? Icon(TablerIcons.users, color: scheme.onSurface.withValues(alpha: 0.5))
                                : Image.memory(Uint8List.fromList(_picture!.bytes), fit: BoxFit.cover),
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: CircleAvatar(
                              radius: 10,
                              backgroundColor: scheme.primary,
                              child: const Icon(TablerIcons.camera, size: 11, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
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
                            borderSide: BorderSide(color: scheme.onSurface.withValues(alpha: 0.1)),
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
                    color: scheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ),
              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nobody else has connected yet.',
                    style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.55)),
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
