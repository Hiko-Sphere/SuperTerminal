# The capture fixture: one container that can serve every screenshot.
#
# Real software throughout — OpenSSH, tmux, TigerVNC's Xvnc, fluxbox, a Python HTTP
# service. Nothing here simulates a result. What is invented is only the *identity*: the
# account is `deploy`, the machine is named by the run, and every file under /home/deploy
# was written for this purpose. Nothing belonging to whoever runs the capture is present.
#
# It provides, on one host, everything the eight screens need:
#   sshd      :22    — shells, SFTP, agent forwarding, jump chains
#   Xvnc      :5901  — a genuine X desktop, reached through the SSH connection
#   http      :8080  — something for a port forward to point at
#   tmux             — a real control-mode server
FROM alpine:3.22

RUN apk add --no-cache \
      openssh-server bash git htop vim coreutils ncurses tzdata \
      # Alpine ships the SFTP subsystem separately from sshd. Without it the file
      # browser connects and then lists nothing, because the subsystem request fails.
      openssh-sftp-server \
      tmux \
      xvfb x11vnc fluxbox xterm xsetroot font-dejavu \
      python3

# The account the screenshots show. Fictional, unprivileged, created here rather than
# reused from the host, so no real user name can reach a screenshot.
RUN adduser -D -s /bin/bash deploy \
 && mkdir -p /home/deploy/.ssh \
 && chmod 700 /home/deploy/.ssh \
 # `adduser -D` leaves `!` in the shadow file, which OpenSSH reads as a locked account
 # and refuses even for a key. `*` means "no password login", which is what is wanted.
 && sed -i 's|^deploy:!:|deploy:*:|' /etc/shadow

# Host keys are generated per build; the app's trust-on-first-use prompt sees a real one.
RUN ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config
COPY bashrc /home/deploy/.bashrc
# OpenSSH starts the account's shell as a *login* shell, which reads /etc/profile and not
# ~/.bashrc — so the prompt the screenshots show has to live here too.
COPY bashrc /etc/profile.d/apexterminal.sh
COPY seed-home.sh /usr/local/bin/seed-home.sh
COPY desktop.sh /usr/local/bin/desktop.sh
COPY service.py /usr/local/bin/service.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/seed-home.sh /usr/local/bin/entrypoint.sh /usr/local/bin/desktop.sh \
 && chown -R deploy:deploy /home/deploy

ENV TZ=UTC
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
