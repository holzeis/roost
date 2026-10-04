# App Review reply — Guideline 2.1, Information Needed

Paste the text under "Reply" into the App Store Connect reply, and the same text into
App Review Information → Notes. Item 1 (the screen recording) must be recorded by hand; see
the checklist at the bottom.

## Reply

**2. Purpose and target audience**

Roost is a private chat and video-calling app for one family. It is for the members of a
single family (single digits to low tens of people) who run their own server at home. It is
not a public network and has no sign-up. It solves unreliable family video calls (VoIP that
often fails to ring or connect). It gives family members chat with photos, video and
live-location sharing, and calls that ring like a native phone call on the lock screen.

**3. How to access the main features (no login needed)**

Roost has no accounts, usernames or passwords. Each family runs its own server on a private
Tailscale network, and a person's device identity on that network is their identity in the
app. Reviewers cannot join a family's private network, so the app has a built-in demo that
needs no server and no credentials:

1. Launch the app. It shows a "can't reach the server" screen.
2. Tap **Explore the demo**.
3. You are signed in as a demo user with sample family chats. Browse the chat list, open a
   conversation, send text, send a photo or video from the photo library, share a location,
   react to a message with an emoji, reply, edit, forward and delete a message, and change
   the light/dark theme.
4. Nothing leaves the device in the demo. All demo data is in memory and is discarded when
   the demo is left.

Calls need a second participant and a media server, so in the demo the call button explains
that calls are unavailable. In a real deployment, calls go through a self-hosted LiveKit
server.

**4. External services used**

- Tailscale: private network and device identity for a real deployment. The demo does not
  use it.
- Self-hosted chat server, Postgres and SeaweedFS (S3-compatible storage), run by the
  family. Not third-party services.
- LiveKit (self-hosted): video and audio calls.
- Apple Push Notification service (incoming-call wake-up via PushKit/CallKit) and Firebase
  Cloud Messaging (new-message notifications). Message previews in notifications are
  end-to-end encrypted to the receiving device.
- Google Maps (map display, and a static map image for ended location shares, fetched by
  the family's server).
- Link previews: the family's server fetches the Open Graph metadata of URLs that members
  paste into chat.

No payment processors, advertising, analytics or AI services are used.

**5. Regional differences**

None. The app and its features are identical in all regions.

**6. Regulated industry / third-party material**

Not applicable. Roost is not in a regulated industry and contains no protected third-party
material.

**Account deletion, reporting and blocking**

- The app does not support account creation, so there is no account to delete. A person is
  identified by their device on the family's private network, and the family's administrator
  removes a person by removing the device from the network. Data in the demo is discarded
  when the demo is left.
- There is no public content. Only members of one family, who are all personally known to
  each other, can see or send content, and it is never visible to anyone outside the
  family's private network.
- There is no payment, subscription or paid content.

## Before sending

- [ ] Item 1: record the screen recording on a physical iPhone on the latest iOS: launch the
      app, show the "can't reach the server" screen, tap **Explore the demo**, then walk
      through the flow in step 3. Show sending a message, a photo and a location share,
      deleting a message, and leaving the demo.
- [ ] Confirm the demo is in the submitted build (`DEMO_AVAILABLE` on).
- [ ] Confirm the claims above against the build: Google Maps use, the "no analytics"
      statement and "identical in all regions".
- [ ] Paste the text into both the reply and the Notes field.
