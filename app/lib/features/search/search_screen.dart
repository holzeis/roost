import 'package:flutter/material.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.roomId});

  final String roomId;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchResult {
  const _SearchResult(this.senderName, this.dayLabel, this.before, this.match, this.after);
  final String senderName;
  final String dayLabel;
  final String before;
  final String match;
  final String after;
}

const _mockResults = [
  _SearchResult('Sam', 'Mon', 'Booked the ', 'cabin', ' for the weekend trip'),
  _SearchResult('Dad', 'Mon', 'Does the ', 'cabin', ' have wifi?'),
  _SearchResult('Sam', 'Tue', 'Sent a photo of the ', 'cabin', ''),
];

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController(text: 'cabin');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
            hintText: 'Search messages',
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('${_mockResults.length} results', style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _mockResults.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final r = _mockResults[index];
                return ListTile(
                  leading: CircleAvatar(radius: 13, child: Text(r.senderName[0], style: const TextStyle(fontSize: 10))),
                  title: Text('${r.senderName} · ${r.dayLabel}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                  subtitle: RichText(
                    text: TextSpan(
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      children: [
                        TextSpan(text: r.before),
                        TextSpan(
                          text: r.match,
                          style: const TextStyle(backgroundColor: Color(0x59FACC15)),
                        ),
                        TextSpan(text: r.after),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
