import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../util/time_format.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  AsyncValue<List<ApiMessage>> _results = const AsyncData([]);

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() => _results = const AsyncData([]));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    setState(() => _results = const AsyncLoading());
    try {
      final messages = await ref.read(apiClientProvider).searchMessages(widget.roomId, query);
      if (mounted && query == _query) {
        setState(() => _results = AsyncData(messages));
      }
    } catch (error, stack) {
      if (mounted && query == _query) {
        setState(() => _results = AsyncError(error, stack));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    final meId = ref.watch(meProvider).valueOrNull?.id;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
            hintText: 'Search messages',
          ),
        ),
      ),
      body: _results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Search failed.\n$error')),
        data: (results) {
          if (_query.isEmpty) return const SizedBox.shrink();
          if (results.isEmpty) return const Center(child: Text('No results'));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('${results.length} results', style: Theme.of(context).textTheme.labelSmall),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final message = results[index];
                    final senderName =
                        message.senderId == meId ? 'Me' : (usersById[message.senderId]?.displayName ?? '?');
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 13,
                        child: Text(senderName.isNotEmpty ? senderName[0].toUpperCase() : '?', style: const TextStyle(fontSize: 10)),
                      ),
                      title: Text(
                        '$senderName · ${formatActivityTime(message.createdAt)}',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                      ),
                      subtitle: _highlighted(message.body ?? '', _query, scheme),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _highlighted(String text, String query, ColorScheme scheme) {
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matchIndex = lowerText.indexOf(lowerQuery);
    if (matchIndex < 0 || query.isEmpty) {
      return Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant));
    }
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        children: [
          TextSpan(text: text.substring(0, matchIndex)),
          TextSpan(
            text: text.substring(matchIndex, matchIndex + query.length),
            style: const TextStyle(backgroundColor: Color(0x59FACC15)),
          ),
          TextSpan(text: text.substring(matchIndex + query.length)),
        ],
      ),
    );
  }
}
