import 'package:go_router/go_router.dart';

import '../data/api_models.dart';
import '../features/call/call_screen.dart';
import '../features/call/incoming_call_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/home/home_screen.dart';
import '../features/new_group/new_group_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/search/search_screen.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/contacts', builder: (context, state) => const ContactsScreen()),
    GoRoute(path: '/contacts/new-group', builder: (context, state) => const NewGroupScreen()),
    GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
    GoRoute(
      path: '/chat/:roomId',
      builder: (context, state) => ChatScreen(
        roomId: state.pathParameters['roomId']!,
        room: state.extra as ApiRoom?,
      ),
    ),
    GoRoute(
      path: '/chat/:roomId/search',
      builder: (context, state) => SearchScreen(roomId: state.pathParameters['roomId']!),
    ),
    GoRoute(
      path: '/call/:roomId',
      builder: (context, state) => CallScreen(
        roomId: state.pathParameters['roomId']!,
        isGroup: state.uri.queryParameters['group'] == 'true',
      ),
    ),
    GoRoute(
      path: '/call/:roomId/incoming',
      builder: (context, state) => IncomingCallScreen(
        roomId: state.pathParameters['roomId']!,
        callerName: state.uri.queryParameters['caller'] ?? 'Unknown',
      ),
    ),
  ],
);
