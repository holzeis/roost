# Roost — instructions for Claude Code

Roost is a self-hosted family chat, media sharing, and video calling app, running on a home Tailscale network with no open ports. This file governs how work on this repo should be done.

## Source documents — read first, every session

These are the source of truth. Read them before starting any task in this repo:

- `docs/architecture-overview.md` — goals, non-functional requirements, architecture principles, high-level architecture, build-vs-reuse choices, and every architecture decision with its rationale
- `docs/functional-requirements.md` — the full functional requirements list, organized by area, with MoSCoW priorities
- `docs/mockups/roost-mockups-utility-dense.html` — reference UI mockups for all screens in the chosen design direction (utility dense)
- `assets/logo/roost-logo.svg` — the app logo (slate blue house-bubble mark)

If any of these paths don't exist yet in the repo, ask where they've been placed rather than guessing or proceeding without them.

## How to work

- Build the application described in the documents above. Don't invent scope beyond what's written there, and don't silently drop anything listed as Must.
- When a direction isn't covered by the documents, or the documents are ambiguous or seem to conflict, stop and ask the user rather than guessing or picking a default silently.
- When the user's answer adds or changes something durable (a decision, a requirement, a data model change), update the corresponding source document as part of that same change, not as a follow-up:
  - Architecture decisions, principles, or NFRs → `docs/architecture-overview.md`
  - Feature-level behavior or scope → `docs/functional-requirements.md`
  - New screens or flows → note in the mockups doc or ask whether a new mockup is needed
- Treat these documents as living — keep them accurate as the app evolves, not just as a one-time input.

## Data model

- Maintain a single current data model as the schema evolves — `docs/data-model.md` plus the actual schema/migration files are both sources of truth and must stay in sync.
- Cover at minimum: users, rooms/room membership, messages (including the media and location subtypes, with `expires_at` for location shares per the architecture doc), media object references, devices/push tokens.
- Any schema change updates `docs/data-model.md` in the same commit as the migration.

## Local development

- The full stack runs locally via `docker-compose.yml` — chat server, Postgres, MinIO, and LiveKit, mirroring the services described in the architecture doc.
- Keep the compose setup functional and current; anyone should be able to clone the repo and run the whole backend locally with one command.

## iOS simulator setup

- Set up and document a local development environment for running the Flutter app on an iOS Simulator (Xcode, CocoaPods, simulator target selection, `flutter run` instructions). Keep this documented in `docs/ios-dev-setup.md` or the README, and keep it current if the setup steps change.

## Testing

- Every feature requires both unit tests and integration tests before it's considered done. Neither is optional, and "I'll add tests later" is not an acceptable state to commit.
- Tests must actually exercise the feature's behavior, not just its happy path.

## Security

- Security is non-negotiable. No shortcuts, no "temporary" insecure code paths, no deferred security work.
- Never read, request, print, log, or commit secrets — API keys, tokens, passwords, certificates, `.env` file contents, or anything similar. If a task needs a secret, tell the user what needs to be configured (an environment variable name, a Kubernetes Secret key, etc.) and let them handle the value out-of-band. Never ask the user to paste a secret into the conversation.
- Apply this to config templates too: commit `.env.example` with placeholder values, never a real `.env`.

## Deployment

- Target deployment is a homelab k3s cluster. Maintain plain Kubernetes manifests (no Helm) under `k8s/` or `deploy/`, kept in sync with the services defined in `docker-compose.yml` and with the architecture doc's decision to use the Tailscale Kubernetes operator for exposing services on the tailnet.
- The app and all its container images must run on both amd64 and arm64.

## CI/CD

- Maintain a GitHub Actions pipeline that builds and tests the app for both amd64 and arm64.
- Maintain a separate, fast release pipeline for shipping to the Android and iOS app stores (e.g. internal testing track / TestFlight), kept distinct from the main build-and-test pipeline so releases aren't blocked on the full CI matrix unnecessarily.

## Git workflow

- Every change is committed with a Conventional Commits message (https://www.conventionalcommits.org/en/v1.0.0/) — `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, `refactor:`, etc., with a scope where it adds clarity (e.g. `feat(chat): add message search`).
- Keep commits scoped to one logical change; don't bundle unrelated changes together to save a commit.
- Commit finished, verified work into cohesive commits without waiting to be asked, and push to `origin` afterward.
