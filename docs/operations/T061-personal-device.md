# Personal-device installation

The personal-device variant uses the real Staging backend and normal Keychain
session storage. It is not a demo or an App Store release.

For a Personal Team that cannot provision Sign in with Apple or the configured
App Groups, use a private build override:

- `SWIFT_ACTIVE_COMPILATION_CONDITIONS=PERSONAL_DEVICE` hides Apple sign-in and
  account-linking controls. Email OTP authentication remains unchanged.
- `CODE_SIGN_ENTITLEMENTS` points to a local empty entitlement plist. Apply this
  override consistently to the application and embedded widget targets.
- Set `APP_GROUP_IDENTIFIER` to an empty string. The existing widget store then
  reports itself unavailable; do not claim shared widget data works in this build.
- Keep automatic development signing enabled and select the owner's actual team.
  Do not commit account identifiers, profiles, certificates or signing secrets.

The default configurations and entitlement files remain unchanged. Do not use
the personal variant as evidence for Apple sign-in or shared-widget acceptance.
No authentication fallback, fake session, or alternative credential storage is
introduced. Use a normal trusted HTTPS endpoint; do not relax transport security.

Before installing, verify the complete signed application, embedded extension,
provisioning profile device membership and expiration, environment, and backend
URL. Install an update over an existing bundle without deleting its data. A
Personal Team profile expires after seven days; rebuild and reinstall with the
same identity before/after expiration as needed.

Device pairing, Developer Mode, Apple Account sign-in, system trust prompts and
any required Apple agreements are performed by the device owner. After launch,
the owner signs in using their own email. Installation alone does not establish
full acceptance of photos, AI, offline synchronization or deletion.
