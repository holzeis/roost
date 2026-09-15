import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/back_button.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _nameController = TextEditingController();
  String? _loadedForUserId;
  bool _saving = false;
  late final ProviderSubscription<AsyncValue<ApiUser>> _meSubscription;

  @override
  void initState() {
    super.initState();
    // fireImmediately matters here: meProvider is very likely already
    // resolved by the time this screen mounts (Home watches it first), so a
    // plain listen would only catch a loading->data transition that already
    // happened before this widget existed. listenManual (initState-only,
    // unlike ref.listen) is what supports fireImmediately in this version.
    _meSubscription = ref.listenManual(meProvider, (previous, next) {
      final user = next.valueOrNull;
      if (user != null && _loadedForUserId != user.id) {
        _loadedForUserId = user.id;
        _nameController.text = user.displayName;
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _meSubscription.close();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveIfChanged(String currentDisplayName) async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty || newName == currentDisplayName) return;
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).updateMe(displayName: newName);
      ref.invalidate(meProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final me = ref.watch(meProvider);

    return Scaffold(
      appBar: AppBar(leading: const TablerBackButton(), title: const Text('Profile')),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    (me.valueOrNull?.displayName.isNotEmpty ?? false) ? me.value!.displayName[0].toUpperCase() : '?',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: const Icon(TablerIcons.camera, size: 11, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
            child: TextField(
              controller: _nameController,
              enabled: me.hasValue,
              decoration: InputDecoration(
                labelText: 'Display name',
                suffixIcon: _saving ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ) : null,
              ),
              onSubmitted: (_) => _saveIfChanged(me.value?.displayName ?? ''),
              onTapOutside: (_) => _saveIfChanged(me.value?.displayName ?? ''),
            ),
          ),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(TablerIcons.wifi),
            title: const Text('Tailnet identity'),
            subtitle: Text(me.hasValue ? 'Resolved from your Tailscale connection' : 'Loading…'),
          ),
          ListTile(
            leading: const Icon(TablerIcons.moon),
            title: const Text('Theme'),
            subtitle: Text(_label(themeMode)),
            trailing: const Icon(TablerIcons.chevronDown),
            onTap: () => _pickThemeMode(context, ref),
          ),
        ],
      ),
    );
  }

  String _label(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System',
      };

  Future<void> _pickThemeMode(BuildContext context, WidgetRef ref) async {
    final selected = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ThemeMode.values)
              ListTile(
                title: Text(_label(mode)),
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await ref.read(themeModeProvider.notifier).setThemeMode(selected);
    }
  }
}
