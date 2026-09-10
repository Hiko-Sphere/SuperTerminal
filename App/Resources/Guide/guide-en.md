<!-- topic: getting-started -->
## Your first connection

Tap **+** on the connection list and paste the address. It is taken apart for you:
`deploy@build.example.com:2222`, `ssh://deploy@host:2222` and `[2001:db8::1]:22` all
work. A blank port means 22. A blank user name is asked for each time the connection
opens, which is what you want on a machine you sign in to as more than one person.

The first time you connect, the server shows you its host key fingerprint and nothing
happens until you accept it. That check is yours to make — see **Host keys**. After that
it is remembered.

Everything else on the connection screen has a working default. You can save a
connection with nothing but an address and come back to the rest later.

<!-- topic: signing-in -->
## Signing in

Apex Terminal offers what you have configured, in the order servers expect, and falls
back to asking:

- **A private key.** Choose one under **Private key**. Keys never leave the device.
- **A password.** Turn on **Offer a password**. Leave the field empty to be asked each
  time instead of storing it.
- **Questions from the server.** Some servers ask instead of accepting a password —
  a one-time code, a token, a new password because the old one expired. Apex Terminal
  shows exactly what the server asked, word for word, and sends back exactly what you
  typed. Answers are never stored.
- **Nothing configured.** With no key and no password chosen, the server is asked what
  it accepts, and you are prompted only for what it will actually take.

If your key has an OpenSSH certificate next to it, that certificate is offered first and
the plain key second, so a server that trusts your CA lets you in without ever having
seen your key.

<!-- topic: keys -->
## Keys on this device

**Settings → Keys** holds them. You can generate a key or import one.

Generating gives you a choice that matters:

| Kind | Where the private half lives | Trade-off |
| --- | --- | --- |
| Ed25519 or ECDSA P-256 | This device's Keychain | Can be backed up, and copied to another device through a backup file |
| Secure Enclave (P-256) | Inside the Secure Enclave | Cannot be extracted, backed up or copied — not by this app, not by anyone. If the device is lost, the key is gone |

A Secure Enclave key can be set to require Face ID or Touch ID for **every single
signature**, which means every connection that uses it. That is the strongest option the
hardware offers, and the one to pick for a key that reaches something important.

Importing accepts OpenSSH private keys, including passphrase-protected ones (`ssh-rsa`,
`ecdsa-sha2-nistp256`, `ssh-ed25519`). The passphrase is used once, to unwrap the key, and is not
kept.

Every key's public half can be copied from the key list, which is what you paste into a
server's `authorized_keys`.

<!-- topic: agent-forwarding -->
## Letting a server use your key

Agent forwarding — **Let this server use my key**, on the connection — lets a program
running on the server ask *your device* to sign something, so you can reach a second
server, or a Git remote, from a shell on the first. The key itself never goes anywhere.

It is off by default, and it should stay off for machines you do not control. While you
are connected, anything running as root on that server can ask your device to sign, for
anything at all, including connections to other servers you use. It cannot read the key,
and signing stops the moment you disconnect — but for as long as the session is up, that
server can act as you.

Only the key that connection already uses is offered. Nothing else on the device is
reachable.

<!-- topic: host-keys -->
## Host keys and what a change means

Every server proves who it is with a host key. On the very first connection there is
nothing to compare against, so you are shown the fingerprint and you decide — compare it
against what the server's operator published, or what `ssh-keyscan` printed on a machine
you already trust.

After that, the key is remembered in **Settings → Known hosts**, and a server whose key
has changed is **refused**. The connection stops before your password or your key is
offered. There is no setting to skip this check.

A changed key has two ordinary causes: the server was rebuilt, or the fingerprint you
are seeing belongs to somebody else. Apex Terminal cannot tell those apart and does not
guess. If you know the server was rebuilt, remove the old entry from **Known hosts** and
accept the new key deliberately.

**Trusted authorities** is the other half of this. Add a CA's public key and every host
key it has signed is accepted without a per-host decision — the standard way to run a
fleet without a growing pile of fingerprints.

<!-- topic: cloudflare -->
## Cloudflare Access and Tunnel

A server published through Cloudflare Tunnel has no open SSH port to connect to. Turn on
**Through Cloudflare Tunnel** and Apex Terminal builds the tunnel itself — there is no
`cloudflared` to install, and nothing to run alongside it.

Two ways to sign in:

- **Browser login** opens Cloudflare Access in the system browser, where you use whatever
  identity provider your organisation runs. The token comes back to the app sealed, is
  stored in this device's Keychain, and is used only for that hostname.
- **Service token** signs in without a browser. Create one in Cloudflare Zero Trust →
  Access → Service Auth and allow it in the application's policy. It is kept in the
  Keychain, never synced, and deleted with the connection.

When a Cloudflare connection fails, the error usually comes from Access rather than from
SSH, so **Access Diagnostics** checks the hostname itself and tells you what it found:
whether the hostname is behind Access at all, which login methods the application offers,
whether the token this device holds is still valid and when it expires. It can also sign
out of that one application without touching your other Cloudflare sessions.

**Settings → Sign out of all Cloudflare Access apps** clears every token on the device.

<!-- topic: jump-hosts -->
## Reaching a server through another

A server you cannot reach directly is reached through one you can. Add jump hosts on the
connection and they are used in order: the first is connected to, a channel is opened
through it to the second, and so on to the destination.

Each hop authenticates as itself, with its own key or password, and each hop's host key
is checked the same way as any other. Nothing is relaxed because a connection is
intermediate.

<!-- topic: terminal -->
## The terminal

Full xterm-256color emulation, true colour, wide characters and combining marks, with a
scrollback you set in **Settings → Terminal**.

On a phone or an iPad without a hardware keyboard, the row above the keyboard has the
keys a touch keyboard does not: Control, Escape, Tab, the arrows. Tap **Control** and it
latches for the next key, so Control then C sends `^C`. Hold it to keep it down.

- **Select text** by touch and hold; the selection can be extended by its handles.
- **Find** with ⌘F, or from the toolbar — matches are highlighted and you can step
  through them.
- **Paste** is confirmed when the text has more than one line, so a stray clipboard
  cannot run a command you did not read. That check can be turned off.
- **Text size** is ⌘+ (or ⌘=) and ⌘−, ⌘0 for the original.
- **The font** is in **Settings → Appearance**: any monospaced face on the device, a line
  height to give long output more or less air, and ligatures if the font has them. Only
  fonts where every character is the same width are offered, because a terminal draws a
  grid. Changing any of them re-measures the screen and tells the server, so full-screen
  programs stay the right size. A sample under the controls is drawn with the same face and
  the same row height the terminal will use, so a zero can be told from an `O` before you
  leave the screen.
- **Split the screen** with ⌘D (to the right) or ⇧⌘D (below) for another shell on the same
  server. **⌥⌘D — or *Split With…* in the Session menu — asks what to put there instead**: a
  different server, a folder, a machine's screen over VNC, something already open, or a server
  that is not in your list yet, which opens the editor and puts what you save straight into the
  pane. ⌥⌘[ and ⌥⌘] move between panes, ⌥⌘W closes one.
- **Themes** and light/dark following the system are in **Settings → Appearance**.
- **A picture behind the terminal** is in **Settings → Backdrop**. How much of it shows is not a
  slider you have to find a readable setting on: it is worked out from the picture itself and the
  theme you are using, so the text keeps the share of contrast the strength you chose promises.
  Softening a picture flattens it, which usually lets more of it through. Turning on **Reduce
  Transparency**, **Increase Contrast** or **Differentiate Without Colour** hides the picture
  entirely and the setting says which one did it.
- **Shell integration** is understood where a shell offers it: the app follows the working
  directory a shell reports, and knows where a prompt and its output begin. A program can
  also ask to copy to your clipboard — `tmux` and `vim` do — which is off until you allow
  it in **Settings → Security**. Reading your clipboard is never allowed.
- **Pictures** a program draws appear in the grid: **sixel**, which `img2sixel`, `gnuplot`
  and `lsix` produce; the **Kitty** graphics protocol; and **iTerm2**'s inline images. They
  scroll with the text, and go when something writes over them or the window changes width —
  a rewrapped line is a different set of cells. The app tells the server how large a cell is,
  so a program can size a picture properly. Two things are refused, and
  the reason is worth knowing. Kitty can also hand a picture over as a *file path*, a
  temporary file or shared memory: those name the filesystem of the machine running the
  program, which over a connection is the server, so they are answered with
  `ENOTSUPPORTED` rather than quietly dropped. And iTerm2's `File=` without `inline=1` is a
  request to save a file the server chose onto your device, which this app does not do.

If the connection drops and **Reconnect automatically** is on, it comes back on its own
as soon as the network does. Your scrollback is kept and the new shell is marked in the
terminal — it starts fresh, in the home directory, with nothing running. A shell that
looks like it lost your work did not: that work was on the old connection, which is gone.

<!-- topic: panes -->
## Several things on one screen

A session can be split so more than one thing is visible at once — two shells, a shell
and a remote screen, four shells, whatever the space allows.

| Action | Keys |
| --- | --- |
| Split to the right | ⌘D |
| Split downwards | ⇧⌘D |
| Close this pane | ⌥⌘W |
| Next pane | ⌥⌘] |
| Previous pane | ⌥⌘[ |

Without a hardware keyboard the same commands are in the **Session** menu in the
toolbar. It works on a phone as well as an iPad, where the panes share one toolbar and it
belongs to whichever pane is focused. Drag the divider between two panes to change how the space is shared; a pane
cannot be dragged down to nothing. The focused pane has an accent border, and VoiceOver
announces it as focused.

Tapping a connection in the list replaces the arrangement rather than adding to it —
splitting is a deliberate action, not something that happens because you opened
something.

<!-- topic: tmux -->
## tmux

Turn on **Attach to tmux** for a connection and opening it attaches to a tmux session on
the server instead of starting a plain shell — creating that session if it is not there.
What is running keeps running when you disconnect, and picking the connection up again on
another device finds it exactly where you left it.

In a tmux session the *server* owns the arrangement. The panes on screen are tmux's own
windows and panes, drawn where tmux says they are, so an arrangement made from a laptop is
the arrangement you see here. The **tmux** menu in the toolbar lists the windows, makes new
ones, splits and closes panes, and detaches.

- **Detach** leaves everything running. It is not the same as disconnecting by accident,
  and it is the normal way to put the session down.
- The session is named in the connection's settings. Leave it blank for `apex`; give it a
  name to keep separate sets of work apart.
- tmux must be installed on the server. If it is not, the app says so rather than dropping
  you into a shell you did not ask for.

The app's own split panes (⌘D) are for ordinary sessions. Inside tmux, use tmux's — two
things deciding one layout would fight, and the server would win.

<!-- topic: sessions -->
## Sessions and reused connections

Every connection you open is a session, listed in the sidebar and reachable with ⌘1
through ⌘9, ⌘] and ⌘[. ⌘W closes the one you are looking at.

Opening a second session on a server you are already connected to does not open a second
connection. Apex Terminal reuses the one that is already up, as long as everything about
it matches — the same host and port, the same user name, the same key or password, the
same jump hosts, the same tunnel. That is one authentication instead of two, one
Face ID prompt instead of two, and one connection for the server to account for. A shell,
a file browser and a port forward on the same server share it.

Change any of those things and you get a separate connection, because a connection
authenticated as somebody else is not the same connection. When the last thing using it
closes, it is kept briefly in case you come straight back, then closed.

<!-- topic: files -->
## Files

Every connection has a file browser: SFTP over the same connection, with no separate
sign-in.

- Browse, sort by name, size or date, and go up with the toolbar.
- **Several folders at once.** Each browser is a session of its own, listed under *Open file
  browsers*, so you can have two open on the same server or on different ones — and on an iPad
  you can put one in each pane and drag between them.
- **Upload** from anywhere iOS can reach; **Download** to the Files app; **Quick Look**
  to read something without downloading it first.
- Rename, delete, make folders, and edit permissions — the mode is shown as the
  read/write/execute grid and as the octal number, and they stay in step.
- Transfers run in a queue you can watch, with progress per file, and they survive
  moving between folders.

Turn on **Show in the Files app** for a connection and the server appears in the Files
app itself, alongside iCloud Drive — so any app that can open a document can open one
from your server. Credentials for that stay in the app's own Keychain access group; the
extension gets no more access than it needs.

<!-- topic: forwarding -->
## Port forwarding

**Forwards** on a connection carries the three kinds `ssh` has, with the same meanings:

| Kind | What it does |
| --- | --- |
| Local | A port on this device is forwarded to an address the server can reach |
| Remote | A port on the server is forwarded back to an address this device can reach |
| Dynamic (SOCKS5) | A SOCKS5 proxy on this device, routed through the server |

Local and dynamic forwards listen on this device, so anything on it — a browser, an app
you are testing — can use them. A remote forward listens on the server, and unless its
`sshd` sets `GatewayPorts`, it can only bind `127.0.0.1` there; asking for anything else
is refused by the server, not by this app. Port 0 asks the server to choose, and the
port it chose is shown once the forward is up.

Each forward shows whether it is listening, what it is bound to, how many connections are
open through it, and how much has been sent and received. A forward runs only while the
app is running and the connection is open.

<!-- topic: screens -->
## Remote screens

A screen is a whole desktop over VNC, and it can travel inside an SSH connection so
nothing needs to be exposed to the network. **How it connects** offers three routes:
**Through SSH** (a channel inside a connection you already have), **Cloudflare** (through
a tunnel, the same as a terminal), or **Direct** for a server you can already reach.

Touch is mapped the way you would expect: tap to click, hold to drag, two fingers to
scroll, pinch to zoom into a corner of a large desktop — once zoomed, two fingers pan
instead. A hardware keyboard and a trackpad or mouse work as themselves.

Authentication follows what the server offers — the classic VNC password, or VeNCrypt's
plain and VNC-authentication sub-types for servers that use them. A user name is only
needed where the server signs in to an account: a Mac sharing its screen, or a VeNCrypt
server. Passwords are kept in this device's Keychain, never in the screen's record; leave
one empty to be asked when the screen opens.

VeNCrypt's own TLS sub-types are not supported. When a server offers only those, the
screen says so rather than falling back to something weaker.

<!-- topic: snippets -->
## Snippets and the command palette

A snippet is a command you stop retyping. Save it in **Settings → Snippets** and it is
one tap away in any session.

⌘K opens the command palette, which searches your open sessions, your connections, your
snippets and every action at once. Type a few letters of any of them; Return runs the
first result.

**Record command history** is off by default. Turn it on and what you have run is offered
back to you; turn it off and what was recorded is deleted. It is stored on this device
only and is never synced.

<!-- topic: links -->
## Links, search and shortcuts

Three ways to reach a connection without opening the app first.

**Links.** `ssh://deploy@build.example.com:2222` opens that server; `apexterminal://open?host=Web`
opens a saved connection by name. A link can also carry a command —
`apexterminal://run?host=Web&command=uptime` — and that is where the app is careful: any link
carrying a command, and any link naming a server you have not saved, is shown to you first
with the server and the command spelled out. Nothing is sent until you allow it, and a link
can never add a connection to your list on its own — it fills in the fields and leaves the
saving to you.

**Spotlight.** Turn on **Find connections in Spotlight** in Settings and your connections
can be searched from the home screen. Only the name and address are indexed — the two lines
the list already shows — and turning it off removes them again. It is off until you turn it
on, because the index can be read without opening this app.

**Shortcuts and Siri.** Three actions: *Connect to Server*, *Run Snippet on Server*, and
*Disconnect All Sessions*. Whether a snippet runs the moment it arrives is the snippet's own
setting, not the shortcut's, so an automation cannot make something run that would not have
run from a tap.

**Handoff.** With a session on screen, another of your devices offers to continue it. An SSH
session cannot travel — the connection and its keys are here — so continuing opens a new
session to the same server. What is handed over is which connection, and nothing else.

<!-- topic: shortcuts -->
## Keyboard shortcuts

With a hardware keyboard everything in the app is reachable without the screen.

| Shortcut | Action |
| --- | --- |
| ⌘N | New connection |
| ⌘K | Command palette |
| ⌘, | Settings |
| ⌘1 … ⌘9 | Go to that session |
| ⌘] / ⌘[ | Next / previous session |
| ⌘W | Close session |
| ⌘D / ⇧⌘D | Split right / down |
| ⌥⌘W | Close pane |
| ⌥⌘] / ⌥⌘[ | Next / previous pane |
| ⌘F | Find in the terminal |
| ⌘+ (or ⌘=) / ⌘− / ⌘0 | Text size |
| ⇧⌘A | Assistant |
| ⌘/ | This guide |

Everything else the terminal claims: ⌃C, ⌃D, ⌃Z, Escape, the function keys and the
arrows all go to the shell, which is where they belong.

<!-- topic: assistant -->
## The assistant

The assistant explains a command, an error or a piece of output. It is off until you set
it up, and it is the one feature in the app that can send text somewhere.

**Prefer the on-device model** keeps everything local where the device supports it.
Otherwise you supply a provider base URL, a model name and an API key, and the text you
send goes to that provider under whatever terms you have with them — not to the
developer, who has no server in this. The API key is kept in this device's Keychain.

Nothing is sent until you ask a question, and what is sent is what you selected.

<!-- topic: privacy -->
## What stays on this device

There is no account, no sign-up and no analytics. Nothing is uploaded, and the app has no
server to upload to.

- **Private keys and passwords** live in this device's Keychain, or inside the Secure
  Enclave for keys generated there. They are never written into the connection list, a
  log, or a diagnostics file.
- **Cloudflare tokens** are Keychain items too, scoped to the hostname they are for.
- **Connections, screens, snippets and known hosts** are ordinary local data.
- **Command history** is off by default, local, and deleted when you turn it off.
- **Diagnostics** — the file you get from **Export diagnostics** — contain no commands,
  no output, no hostnames and no credentials.
- **iCloud sync** is not available in this version. Everything stays on this device.
- **App lock** puts a passcode, Face ID or Touch ID in front of the app itself, and
  **Hide content in the App Switcher** keeps your terminal out of the app switcher's
  snapshot.
- **Backups** are files you make and keep. Include private keys and the file is encrypted
  with a password you type — not stored anywhere, and without it the backup cannot be
  opened by anyone, including you.
- **Delete all data** removes everything: connections, keys, tokens, history, settings.

<!-- topic: troubleshooting -->
## When something goes wrong

**The host key changed.** The connection was refused on purpose. Find out why before you
do anything else; if the server really was rebuilt, delete its entry in **Settings →
Known hosts** and accept the new key.

**Cloudflare says no.** Open **Access Diagnostics** on that connection. It will tell you
whether the hostname is behind Access, what it accepts, and whether the token here is
still valid.

**Authentication keeps failing.** Check the user name — a blank one is asked for at
connect time and it is easy to accept the wrong default. If the server asks questions
rather than taking a password, answer them as asked; they come from the server, not from
this app.

**The server refused agent forwarding.** Many do (`AllowAgentForwarding no`), and the
session works anyway — it just cannot sign for anything on the far side.

**A remote forward will not bind.** Unless the server's `sshd` sets `GatewayPorts`, it
can only listen on `127.0.0.1`. That refusal comes from the server.

**Screens: the server offers only VeNCrypt TLS.** Those sub-types are not supported, and
the app says so rather than negotiating something weaker.

**Something else.** **Settings → Export diagnostics** gives you a file describing what
the app did — versions, timings, error categories — with no commands, output, hostnames
or credentials in it.
