# Security

PocketMac gives a phone full control of a Mac, so security problems matter a lot.

## Reporting a problem

Please **don't open a public issue** for a security problem. Instead, report it privately:
**[Security → Report a vulnerability](https://github.com/Its-Choudhary/pocketmac/security/advisories/new)** on this repository.

If that page isn't available, open an issue that only says you have a security report (no details), and you'll be given a private way to send it.

Include what an attacker could do, the steps to reproduce it, and the versions of the Mac and phone apps. You'll get an answer as soon as possible, and credit in the fix if you'd like.

## What's in scope

- The login handshake, encryption, pairing and lockout (`Shared/`, `android/.../proto/`)
- Anything that lets a device other than a paired phone see the screen or send input
- The Mac app's helper (`/etc/sudoers.d/pocketmac`, allows only `pmset -a disablesleep 0/1`)
- How the phone apps store the saved login

How it's designed, and the known limits: [docs/HOW-IT-WORKS.md → Security](docs/HOW-IT-WORKS.md#security).
