# Roost — functional requirements

First draft, derived from the goals and decisions in the architecture overview. Priorities use MoSCoW (Must / Should / Could) as a starting point for review — adjust freely.

## 1. Chat

| ID | Requirement | Priority |
|---|---|---|
| FR1.1 | Users can create and join rooms, including 1:1 conversations and group rooms | Must |
| FR1.2 | Users can send and receive text messages in real time | Must |
| FR1.3 | Message history is persisted and available when a user reopens the app or joins from a new device | Must |
| FR1.4 | Users can see who else is in a room and its name/members | Should |
| FR1.5 | Users can see delivery status (sent/delivered) for their messages | Should |
| FR1.6 | Users can see read receipts | Could |
| FR1.7 | Users can see a "typing…" indicator from other participants | Could |
| FR1.8 | Users can search for messages within a chat | Must |
| FR1.9 | Users can add emoji reactions directly on a message | Must |
| FR1.10 | Users can reply to a specific message; the reply shows a quoted preview of the original, and tapping the quote scrolls to it | Should |
| FR1.11 | Users can forward a message to another room; forwarded media is duplicated as an independent copy, not shared by reference | Should |
| FR1.12 | Users can copy a text message's content to the clipboard | Could |
| FR1.13 | Users can edit their own text messages within 1 minute of sending | Could |
| FR1.14 | Users see a rich preview (title/description/image) for links shared in a message | Could |
| FR1.15 | Users can delete their own messages (any kind), with a confirmation prompt before it happens. A message that someone has already seen is replaced by a "Deleted message" placeholder for everyone; one nobody has seen yet disappears entirely | Should |

## 2. Media sharing (images & video)

| ID | Requirement | Priority |
|---|---|---|
| FR2.1 | Users can share images from their device into a chat | Must |
| FR2.2 | Users can share videos from their device into a chat | Must |
| FR2.3 | Shared images and videos can be viewed/played inline and downloaded | Must |
| FR2.4 | Shared media persists indefinitely and is not automatically deleted | Must |
| FR2.5 | Users can manually delete media they've shared | Should |
| FR2.6 | Users can attach an optional caption to a photo/video when sharing it | Should |
| FR2.7 | Users can share photos and videos into Roost from other apps via the system share sheet, then pick a chat (most-used first), review, caption and send. The chats a user sends to most also appear directly in the share sheet's row of suggested contacts (iOS conversation suggestions, Android sharing shortcuts), skipping the chat picker | Should |

## 3. Location sharing

| ID | Requirement | Priority |
|---|---|---|
| FR3.1 | Users can share their live location within a chat | Must |
| FR3.2 | The sender selects how long the location will be shared (TTL) at the time of sharing, from a small set of preset durations | Must |
| FR3.3 | While a share is active, recipients see the sender's location update in near-real time — including while the sender's app is in the background, and after the app restarts (it resumes tracking the sender's live shares, or ends them if location access is gone). A person has at most one live share per chat: starting a new one ends the previous one, and deleting a share stops its tracking | Must |
| FR3.4 | Once the TTL elapses, the client stops sending updates and the location is no longer shown as live | Must |
| FR3.5 | The sender can manually end a location share before its TTL elapses | Should |
| FR3.6 | Recipients can see how much time remains on an active location share | Could |
| FR3.7 | A shared location is displayed on a map (e.g. Google Maps) rather than as coordinates/text. The sender's own avatar marks their position in place of a generic pin, on both an active and an ended share; once a share ends, this becomes a single static snapshot of the last known position rather than a live, repeatedly-reloaded map view | Must |
| FR3.8 | When multiple users share their location in the same chat, all active shares are shown together on a single map | Must |

## 4. Voice & video calling

| ID | Requirement | Priority |
|---|---|---|
| FR4.1 | Users can start a 1:1 video call with another user | Must |
| FR4.2 | Users can start a group video call within a room | Must |
| FR4.3 | Users can join a call with audio only (camera off) | Should |
| FR4.4 | An incoming call rings the recipient's device with a native call screen, whether the app is foregrounded, backgrounded, or fully closed | Must |
| FR4.5 | Users can accept, decline, or end a call | Must |
| FR4.6 | Users can mute/unmute their microphone and enable/disable their camera during a call | Must |
| FR4.7 | Users can switch between front/rear camera during a video call | Must |
| FR4.8 | Every call is recorded in the chat/room history with its outcome: the talk time for a call that was answered ("23 sec"), "No answer" on the caller's side and "Missed video call · Tap to call back" on the other side for one that wasn't, or "Declined" | Should |

## 5. Notifications

| ID | Requirement | Priority |
|---|---|---|
| FR5.1 | Users receive a push notification for an incoming call when the app is backgrounded or closed | Must |
| FR5.2 | Users receive a push notification for new messages when the app is backgrounded or closed, showing the sender and a preview of the message (the text, or e.g. "📷 Photo"). The preview is end-to-end encrypted to the receiving device | Should |
| FR5.3 | Users can mute notifications per room | Could |

## 6. Identity & access

| ID | Requirement | Priority |
|---|---|---|
| FR6.1 | A user's identity is derived from their Tailscale account — no separate signup/password | Must |
| FR6.2 | Only devices connected to the family's tailnet can use the app | Must |
| FR6.3 | Users have a display name and profile image visible to others | Must |
| FR6.4 | Users can update their own display name and profile image at any time | Must |
| FR6.5 | Users can see which of their contacts are currently online | Could |
| FR6.6 | Anyone who has opened the app at least once shows up as an available contact everywhere a conversation can be started — including the main conversations list, not only a separate contacts directory — even before any conversation with them exists | Must |

## 7. Platform

| ID | Requirement | Priority |
|---|---|---|
| FR7.1 | Native mobile app for iOS and Android (single Flutter codebase) | Must |
| FR7.2 | The app supports a light theme and a dark theme | Must |
| FR7.3 | The user can set their theme preference to light, dark, or match system | Must |
| FR7.4 | Desktop/web client | Out of scope (deferred) |
| FR7.5 | An in-app demo mode for app store review, offered on the "can't reach the server" screen: a demo user signed in automatically, sample family chats, and no connection to any server. Calls explain they're unavailable. Can be switched off with a build setting | Must |

