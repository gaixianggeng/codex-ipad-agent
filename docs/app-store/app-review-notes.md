# App Review Notes — Mimi Remote 1.0

Mimi Remote is a native developer-tool client for Codex running through a Mac owned by, or explicitly authorized for use by, the user.

The iOS app does not execute downloaded code, provide arbitrary shell access, provide AI models or subscriptions, operate a VPN, or host project data. Code execution occurs on the configured Mac. Model-provider communication is initiated by Codex or another explicitly configured CLI on that Mac and is not relayed through a developer-operated Mimi Remote service.

## Review credentials

Use the isolated review environment below. These credentials are created only for App Review and can access only a disposable sample repository.

- Endpoint: `<REVIEW_HTTPS_ENDPOINT>`
- Access token: `<REVIEW_ACCESS_TOKEN>`
- Environment availability: `<START_DATE_UTC>` through `<END_DATE_UTC>`

Please use manual connection instead of QR pairing because normal QR tickets are intentionally short-lived and single-use.

## Review steps

1. Launch Mimi Remote.
2. Choose manual connection on the Mac Connection screen.
3. Enter the Endpoint and Access token above, then connect.
4. Open the `Mimi Review Sample` workspace.
5. Open the prepared session, or create a new Codex session.
6. Send a prompt such as `Summarize this sample project without changing files.`
7. Open the Changes or Inspector area to review the sample Git status and diff.
8. Optional: request a small README edit and review the approval UI before accepting or declining it.
9. Open Settings → Legal & Support to view the Privacy Policy, Terms of Use, and Support pages.
10. Open Settings → Language to switch between English and Simplified Chinese without restarting the app.

## Network and security model

- The review Endpoint uses HTTPS. Mimi Remote also supports private local/Tailscale HTTP addresses, but blocks public cleartext HTTP in the app.
- The access token is stored in the iOS Keychain.
- The Mac gateway restricts projects to configured roots and exposes an allowlisted protocol surface. It does not expose a general-purpose remote shell.
- The developer does not collect analytics, project content, prompts, credentials, or usage telemetry.

## Optional Claude Code compatibility

The binary contains compatibility with an optional experimental Claude Code bridge that a user may install and explicitly enable on their own Mac. It is not enabled in the review environment, is not required for the core Codex workflow, and does not provide an Anthropic account, subscription, or hosted service.

## Permissions

- Camera: scanning a pairing QR code.
- Microphone and speech recognition: optional user-initiated dictation.
- Local network: connecting to a user-configured Mac.

Manual endpoint entry and keyboard input remain available if camera, microphone, or speech permissions are declined.

Review contact:

- Name: `<REVIEW_CONTACT_NAME>`
- Email: `gaixg94@gmail.com`
- Phone: `<REVIEW_CONTACT_PHONE>`
