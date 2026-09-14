import 'package:flutter/material.dart';

import '../../data/mock_data.dart';
import '../../widgets/avatar.dart';

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : () => Navigator.of(context).pop(),
            child: const Text('Create'),
          ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.group_outlined),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: CircleAvatar(
                        radius: 9,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: const Icon(Icons.camera_alt_outlined, size: 10, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(hintText: 'Group name'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in _selected)
                    Chip(
                      avatar: InitialAvatar(
                        initial: MockData.contacts.firstWhere((c) => c.id == id).initial,
                        size: 16,
                      ),
                      label: Text(MockData.contacts.firstWhere((c) => c.id == id).displayName),
                    ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Add more people', style: TextStyle(fontSize: 11)),
            ),
          ),
          for (final contact in MockData.contacts)
            CheckboxListTile(
              value: _selected.contains(contact.id),
              onChanged: (checked) => setState(() {
                if (checked ?? false) {
                  _selected.add(contact.id);
                } else {
                  _selected.remove(contact.id);
                }
              }),
              secondary: InitialAvatar(initial: contact.initial, size: 26),
              title: Text(contact.displayName),
              controlAffinity: ListTileControlAffinity.leading,
            ),
        ],
      ),
    );
  }
}
