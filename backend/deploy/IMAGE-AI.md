# Photo recognition runtime

The image-capable service replaces the one-shot text-only service for deployments
that explicitly enable recognition. It uses the same restricted database login,
separate scoped claim function, current recipient consent, and existing dispatch
accounting. Do not run both services together.

Apply `neon-ai-worker.sql` transactionally after migrations through 033. Install
`moja-szafa-image-ai-staging.service` and a private `image-ai-staging.env` copied
from the existing AI environment. Set `AI_WORKER_MODE=images` and
`PRIVATE_IMAGE_DIRECTORY=/run/szafa-ai-images` in that file. EnvironmentFile values
take precedence over the unit's Environment entries.

The service reads a read-only bind mount of the private image volume under the
storage owner's Unix identity. The original storage directory (including exports)
and `/proc` are masked, the rest of the filesystem is read-only, capabilities are empty, and
other users' processes are hidden. Verify the mounted thumbnail is readable and
neither the mounted volume nor original private directory is writable/accessible
inside the service sandbox before activation. The trusted runtime loads only the
normalized thumbnail bound to the leased job; it never sends a public URL or EXIF
original to the model.

Before enabling both policy switches, publish a new consent disclosure describing
normalized image transmission and recognition. Existing text-only consents must
not authorize photos. Keep the free Workers AI plan and maximum daily units of
10 globally / 4 per account. Migration 033 stops counting an unused repair reservation after terminal failure; already dispatched calls remain charged. Recognition reserves one unit and has no provider
retry. Gemma 4 vision receives a bounded image and returns the closed recognition
schema. User confirmation is still required before creating a wardrobe garment.

Enable/start the image service only after preflight passes. It survives reboots;
the SQL policy remains the immediate kill switch. To roll back: stop/disable the
image service, disable AI/image policy, restore previous source/unit/environment
and disclosure from the private deployment backup. Do not delete photos/jobs or
reset dispatch accounting. Re-enabling the old text service requires its original
image-disabled policy and matching disclosure.

Verification must include a real, consented test-account image through the public
API, a provider-backed result, native suggestion review/save, and a subsequent
read confirming garment metadata and photo. Fixture-only tests are insufficient.
