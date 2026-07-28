# How TUF Works

The update server leverages TUF to ensure secure OTA delivery. If you
are unfamiliar with TUF, you can learn more from this
[overview](https://theupdateframework.io/docs/overview/).

> [!NOTE]
> The [Quick Start](./quick-start.md) shares how to initialize TUF keys
> and metadata.

Every key generated and used by the update server is encrypted with an
HMAC key. Access to the HMAC key is required for using each of the "online"
keys: Timestamp, Snapshot, and Targets.

## Root Role

The update server uses a single Root key under `<datadir>/tuf/keys/root.key`.
You **must never lose** this key.
A loss of a Root key and/or the HMAC key would make it impossible to add new keys;
in which case there will be no way to sign new Updates after a Root role expires.

The root role is valid for 20 years (root.json's `signed.expires` attribute).

> [!WARNING]
> Backup `<datadir>/tuf/keys/root.key` **and** `<datadir>/auth/hmac.secret` to
> multiple places including [AWS Secret Manager](https://docs.aws.amazon.com/secretsmanager/),
> and a physical copy on paper stored in a safe.

You can remove this key from the server once it's been backed up. It is
considered an "offline" key and is not required by the update server for
normal operations.

## Timestamp Role

The update server uses a single Timestamp key under `<datadir>/tuf/keys/timestamp.key`.
Each Update has its own timestamp.json file. This file is signed with a
1-week expiration value. There is a background task running every 4 hours
that will refresh timestamps expiring in the next 24 hours.

## Snapshot Role

The update server uses a single Snapshot key under `<datadir>/tuf/keys/snapshot.key`.
Each Update has its own snapshot.json file. This file is signed with a
expiration value that matches the Targets expiration.

## Targets Role

The update server uses a single Targets key under `<datadir>/tuf/keys/targets.key`.
This key is used during Update creation to sign the generated targets.json
metadata. The metadata is signed with a 90-day expiration. See
[Updates](./updates.md) for more details.

The Snapshot and Targets expiration values are not automatically refreshed.
It is up to the operator to keep these values fresh for Updates used over
90 days.
