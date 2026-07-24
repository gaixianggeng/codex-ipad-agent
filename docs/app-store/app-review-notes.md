# App Review Notes — Mimi Remote 1.0

Mimi Remote is a native developer-tool client for a computer owned by, or explicitly authorized for use by, the user.

The iOS app does not execute downloaded code, provide arbitrary shell access, provide AI models or subscriptions, operate a VPN, relay traffic, or host project data. Code execution occurs only on the configured host. The developer does not operate a service that receives prompts, source code, credentials, or model-provider traffic.

## Resolution of the previous China mainland issue

- Public App Store metadata and screenshots contain no ChatGPT or OpenAI names, logos, or claims of affiliation.
- Runtime choices use their recognizable product icons only to identify the compatible host-side CLI selected by the user. Mimi Remote does not claim affiliation with or endorsement by those providers.
- The iOS app has no ChatGPT/OpenAI sign-in, API-key field, model subscription, hosted model endpoint, or purchase flow.
- Voice input uses only on-device transcription. Recordings are not sent to a model-provider transcription endpoint.
- Compatible command-line developer runtimes are installed, configured, and authenticated by the user on the host computer. Mimi Remote does not provide or resell access to those tools.

## Review credentials

Use the isolated review environment below. These credentials are created only for App Review and can access only a disposable sample repository.

- Endpoint: `<REVIEW_HTTPS_ENDPOINT>`
- Access token: `<REVIEW_ACCESS_TOKEN>`
- Environment availability: `<START_DATE_UTC>` through `<END_DATE_UTC>`

Please use manual connection instead of QR pairing because normal QR tickets are intentionally short-lived and single-use.

## Review steps

1. Launch Mimi Remote.
2. Choose manual connection on the Connection screen.
3. Enter the Endpoint and Access token above, then connect.
4. Open the `Mimi Review Sample` workspace.
5. Open the prepared session, or create a new coding session.
6. Send a prompt such as `Summarize this sample project without changing files.`
7. Open the Changes or Inspector area to review the sample Git status and diff.
8. Optional: request a small README edit and review the approval UI before accepting or declining it.
9. Open Settings → Legal & Support to view the Privacy Policy, Terms of Use, and Support pages.
10. Open Settings → Language to switch between English and Simplified Chinese without restarting the app.

## Network and security model

- The review Endpoint uses HTTPS. Mimi Remote also supports private local/Tailscale HTTP addresses, but blocks public cleartext HTTP in the app.
- The access token is stored in the iOS Keychain.
- The host gateway restricts projects to configured roots and exposes an allowlisted protocol surface. It does not expose a general-purpose remote shell.
- The developer does not collect analytics, project content, prompts, credentials, or usage telemetry.

## Permissions

- Camera: scanning a pairing QR code.
- Microphone and speech recognition: optional user-initiated dictation.
- Local network: connecting to a user-configured host.

Manual endpoint entry and keyboard input remain available if camera, microphone, or speech permissions are declined.

Review contact:

- Name: `<REVIEW_CONTACT_NAME>`
- Email: `gaixg94@gmail.com`
- Phone: `<REVIEW_CONTACT_PHONE>`
