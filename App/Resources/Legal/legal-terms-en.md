# SuperTerminal — Terms of Use

**Effective date:** 6 September 2026

This document is a template the developer drafted for review by counsel; it is not legal advice and has not been reviewed by a lawyer.

## 1. What these terms cover

These terms apply to the SuperTerminal app for iOS and iPadOS ("the app"), published on the App Store by Li Yanpei ("the developer"). There is no account to create. The app shows these terms, the Privacy Policy and the User Notice the first time it opens and asks you to accept them; continuing to use the app is how you accept them after that. If you do not accept them, delete the app.

These terms are the licence agreement for the app. They take the place of Apple's standard Licensed Application End User License Agreement and include the terms Apple requires, in section 13.

## 2. What the app is

SuperTerminal is an SSH terminal. It connects to servers you choose, either directly or through Cloudflare Tunnel with a Cloudflare Access sign-in performed in a system browser, and shows you a shell on that server. That is the whole product.

There is no account with the developer, no server operated by the developer, and no content hosted by the developer. The app works entirely between your device, the servers you connect to and, when you use a tunnelled host, Cloudflare acting on your behalf. The Privacy Policy says exactly what the app stores and where.

## 3. Your servers, your permission

You may only use the app to connect to systems you are allowed to access: systems you own, systems you administer, or systems whose owner has given you permission. Unauthorised access to a computer is an offence in most countries, and the app has no way to tell whether you are allowed on a machine. You are responsible for following the law where you are and where the server is, and for following any policy your employer or organisation has about remote access.

The app sends what you type to the server you connected to and shows what the server sends back. Everything you type runs on that server under the account you signed in with. What you do in that shell is your doing. The developer cannot see your sessions, cannot reach your servers, and cannot recover anything you change or delete on them.

## 4. Your credentials

The app stores SSH private keys, passwords and Cloudflare Access tokens on your device so you do not have to enter them every time. It sends a credential only to the server you are authenticating to, or, for Access tokens, back to Cloudflare. It never sends a credential to the developer, because the developer has nowhere to receive it.

You are responsible for the security of your device: its passcode, its biometric enrolment, and who can unlock it. A person who can unlock your device and open the app can use the connections and credentials stored in it, subject to any Face ID or Touch ID protection you have chosen for individual keys.

## 5. Host keys and first connections

On the first connection to a server the app shows you the server's key fingerprint and asks you to confirm it. Confirming a fingerprint you have not checked against the server means trusting whoever answered. The app cannot verify a first connection for you; only you can. On later connections the app refuses a changed key until you decide what to do. It will not accept a changed key on its own, and a reconnection after a dropped link goes through the same check.

## 6. Cloudflare

Cloudflare Tunnel and Cloudflare Access are services of Cloudflare, Inc., used under your own Cloudflare account and Cloudflare's own terms, not these. SuperTerminal is not affiliated with, endorsed by or sponsored by Cloudflare. Cloudflare, Cloudflare Tunnel and Cloudflare Access are trademarks of Cloudflare, Inc.

The app speaks to Cloudflare the way Cloudflare's own command-line tool does. If Cloudflare changes that behaviour, tunnelled connections may stop working until the app is updated. The developer will try to keep up but does not promise to. Cloudflare's FedRAMP endpoints are not supported.

## 7. iCloud

Syncing through iCloud is off unless you turn it on. When it is on, the data listed in the Privacy Policy is stored in your own iCloud account under Apple's terms and Apple's encryption. The developer has no access to your iCloud account and cannot read, recover or delete what is stored there on your behalf. Keeping that account secure is your responsibility: any device signed in to it, and trusted for iCloud Keychain, receives the private keys you have allowed to sync. Passwords are never synced. Turning the switch off stops syncing. "Delete all data" also removes the app's data from iCloud.

iCloud, Face ID and Touch ID are services and features of Apple Inc. and are governed by your agreement with Apple.

## 8. Open-source components

The app includes software licensed under the Apache License 2.0 (the swift-nio family and swift-crypto), the ISC licence (swift-sodium and OpenBSD's bcrypt_pbkdf) and the BSD-3-Clause licence (OpenBSD's Blowfish). Some of these are included in modified form, as their licences allow. The licence texts and required notices are included in the app under Settings → Legal → Open-source licences. Those components remain under their own licences; these terms do not change them.

## 9. Licence to use the app

The developer grants you a personal, non-exclusive, non-transferable licence to install and run the app on Apple devices you own or control, as the App Store rules allow. You may not copy, sell, rent or redistribute the app, remove its notices, or reverse engineer it, except where the law gives you that right regardless of this clause. The app's own code, name and design belong to the developer. Nothing in this section narrows the rights the open-source licences in section 8 give you in those components.

## 10. No warranty

The app is provided as it is, without any warranty the law lets the developer exclude. The developer does not promise that the app will be free of defects, that it will remain compatible with future changes to iOS, to SSH servers or to Cloudflare's protocols, or that it will be available or supported for any length of time. In particular, the developer does not promise that:

- the app will connect to every server — a server that offers only an algorithm the app does not implement cannot be reached;
- a connection will stay up, or that a reconnection will find the server in the state you left it — a reconnected shell is a new shell;
- command history, if you turn it on, is complete — a line the remote line editor changed is dropped rather than guessed;
- Cloudflare or iCloud will be available or unchanged.

The app's security design is described in the User Notice and in the project's security documentation. That description is an honest account of what the app does, not a guarantee against every attack. A terminal is a tool for administering systems; a defect in it, or a mistake made with it, can cause loss. You use it at your own risk. Where the law gives you warranty rights that cannot be excluded, those rights are not affected.

## 11. Limitation of liability

To the extent the law that applies to you allows, the developer is not liable for any loss or damage arising from your use of the app or your inability to use it, including indirect or consequential loss and loss of profits, data or business. Without limiting that, the developer is not liable for:

- loss of access to a server, including an account locked by repeated failed sign-ins;
- a command run on the wrong host or in the wrong directory, including after a reconnection;
- anything changed, lost or deleted on a server you connected to;
- loss of keys, passwords or connections after "Delete all data", after deleting the app, or after losing a device;
- a connection you accepted after confirming a fingerprint that was not your server's;
- outages or changes at Cloudflare or Apple.

If the developer is found liable despite the above, that liability is limited to the amount you paid for the app, if anything, or to the minimum liability the law requires, whichever is greater. Nothing in these terms excludes liability for death or personal injury caused by negligence, for fraud, or for anything else that cannot be excluded by law, and nothing removes the protection you have as a consumer where you live.

## 12. Ending your use

You may stop using the app at any time by deleting it. The licence also ends, without notice, if you break section 3 or section 9. The developer may withdraw the app from the App Store or stop maintaining it at any time.

Deleting the app removes its files from the device. iOS does not promise to remove an app's Keychain items when the app is deleted, so if you want your keys, passwords and tokens gone as well, run "Delete all data" in Settings first. If iCloud sync was on, "Delete all data" also clears the iCloud copy; deleting the app alone does not. Nothing about you is held by the developer, so there is nothing for the developer to delete. Nothing about your servers or your Cloudflare configuration changes when you delete the app; revoke keys and sessions there yourself if you want to.

## 13. Terms Apple requires

Apple requires the following when an App Store app has its own terms:

- These terms are between you and the developer only, not Apple. Apple has no responsibility for the app or its content.
- The developer, not Apple, is responsible for maintenance and support. Apple has no obligation to provide any.
- If the app fails to conform to any warranty that applies, you may notify Apple and Apple will refund the purchase price, if any. Apple has no other warranty obligation for the app.
- The developer, not Apple, is responsible for any claim relating to the app, including product liability claims, claims that it fails to meet a legal or regulatory requirement, and consumer protection claims.
- If someone claims that the app infringes their intellectual property, the developer, not Apple, is responsible for dealing with it.
- You confirm that you are not in a country subject to a United States government embargo or designated as "terrorist supporting", and that you are not on any United States government list of prohibited or restricted parties.
- Apple and its subsidiaries are third-party beneficiaries of these terms and may enforce them against you.

## 14. Export

The app contains encryption. You are responsible for complying with the import, export and use laws that apply where you are.

## 15. Changes to these terms

A new version of these terms ships with a new version of the app, dated at the top, and the app shows the changed terms and asks you to accept them again before continuing. If you do not accept them, delete the app.

## 16. Which law applies

These terms do not choose a governing law or a court. Where you live decides: if you are a consumer, the mandatory laws of your country apply, and you may bring a claim there.
