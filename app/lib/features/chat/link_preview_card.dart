import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_providers.dart';

final _urlPattern = RegExp(r'https?://[^\s]+');

/// The first http(s) URL in text, or null. Used to decide whether a text
/// message is worth fetching a link preview for at all (FR1.14).
String? firstUrlIn(String text) => _urlPattern.firstMatch(text)?.group(0);

/// Fetches and renders a link preview card for [url] below a text message.
/// Renders nothing while loading or if the server found no preview for the
/// URL (an ordinary outcome for most links, not worth a placeholder).
class LinkPreviewCard extends ConsumerWidget {
  const LinkPreviewCard(
      {super.key, required this.url, required this.onBackground});

  final String url;

  /// Whether this sits on the primary (sent-by-me) bubble color, so text
  /// contrast can be chosen accordingly.
  final bool onBackground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(linkPreviewProvider(url));
    final scheme = Theme.of(context).colorScheme;
    final fg = onBackground ? scheme.onPrimary : scheme.onSurface;

    return preview.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (data) {
        if (data == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 6),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: fg.withValues(alpha: 0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (data.imageUrl != null)
                Image.network(
                  data.imageUrl!,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) =>
                      const SizedBox.shrink(),
                ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (data.siteName != null)
                      Text(
                        data.siteName!.toUpperCase(),
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: fg.withValues(alpha: 0.6)),
                      ),
                    if (data.title != null)
                      Text(
                        data.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: fg),
                      ),
                    if (data.description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          data.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: fg.withValues(alpha: 0.75)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
