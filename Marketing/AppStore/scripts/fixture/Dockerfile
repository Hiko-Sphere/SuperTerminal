# A real OpenSSH server for capturing App Store screenshots.
#
# Real, not a mock: openssh-server from Alpine, a real key exchange, a real PTY, a real
# shell. What is fictional is only the *identity* — the account is `deploy`, the machine
# is named in the compose script, and every file under /home/deploy is invented for the
# purpose. Nothing here touches a production host, and no credential of the person
# running it is visible to the app.
FROM alpine:3.22

RUN apk add --no-cache openssh-server bash git htop vim coreutils ncurses tzdata

# The account the screenshots show. Fictional, unprivileged, and created here rather
# than reused from the host, so no real user name can reach a screenshot.
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
# OpenSSH starts the account's shell as a *login* shell, which reads /etc/profile
# and not ~/.bashrc — so the prompt the screenshots show has to live here too.
COPY bashrc /etc/profile.d/apexterminal.sh
COPY seed-home.sh /usr/local/bin/seed-home.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/seed-home.sh /usr/local/bin/entrypoint.sh \
 && chown -R deploy:deploy /home/deploy

ENV TZ=UTC
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
