# Opt-in hosted native sign-in acceptance

`HostedStagingAcceptanceTests/testRealEmailLoginAndSessionRestore` exercises the
normal native email sign-in screen, optional onboarding, a server-backed wardrobe,
and session restoration after terminating and relaunching the app. It injects no
session, mock repository, or authentication response into the application.

This test is excluded from ordinary CI. Compile the UI test target for the
simulator with `HOSTED_STAGING_ACCEPTANCE`, using the Staging configuration and
the `MojaSzafaUI` scheme. Do not combine it with demo/layout/benchmark flags.
Use an isolated test simulator and an authorized synthetic account whose hosted
wardrobe contains rows prefixed `Synthetic staging benchmark `.
Keep simulator ad-hoc signing enabled so the real Keychain session store has its
application identity. An unsigned build is not a valid hosted-login environment;
do not replace Keychain with an insecure test store to make sign-in pass.

Before running the generated `.xctestrun`, set both `SystemAttachmentLifetime`
and `UserAttachmentLifetime` to `keepNever` for its test target. Select only the
hosted test and set `HOSTED_PRIVATE_INPUT=1` in `TestingEnvironmentVariables`.
The environment flag is an explicit operator acknowledgement, not automatic
verification that attachment retention is disabled. Do not record the screen.

The external private controller discovers the running UI test runner's data
container. In its Documents directory, the test creates `hosted-email.request`
and later `hosted-otp.request`. Supply a corresponding `hosted-email.json` or
`hosted-otp.json` containing a single `value` string using atomic mode-0600 writes.
The OTP must come from the fresh email requested by the native application.
Do not request or verify a separate authentication challenge in the controller.

The test waits up to 120 seconds for each input, removes the input after reading,
and pastes it through the native text-editing menu. It clears the local-only,
expiring pasteboard after each field. It deliberately avoids `typeText` because
XCTest records typed arguments. Never put credentials in launch arguments,
environment variables, attachments, assertions, or console output. The controller
must clean up input/marker files after any interrupted run. Run on a dedicated
simulator because its pasteboard is cleared.

A pass proves only the tested hosted sign-in, wardrobe read and session-relaunch
path. It does not prove photo processing, AI output, offline convergence, account
deletion, physical-device performance, or release readiness. Record actual run
results separately; the presence of this opt-in test is not a passing result.
