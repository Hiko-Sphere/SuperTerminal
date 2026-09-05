/* A real RFB server for the client's tests, built on LibVNCServer (the library behind
 * x11vnc and many others). It serves a known pattern, optionally requires the classic
 * VNC password, and appends every pointer and key event it receives to a log file so a
 * test can prove the client's input arrived — not merely that bytes were sent.
 *
 *   vnc-test-server <port> <log path> [password]
 *
 * Framebuffer: 320x200, 32bpp. Pattern: pixel (x, y) = R:x&255 G:y&255 B:(x^y)&255, so a
 * decoded framebuffer can be checked pixel by pixel. Every 500 ms a 40x40 square at
 * (100,80) toggles between black and white so incremental updates carry real rectangles.
 */
#include <rfb/rfb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static FILE *logFile;
static rfbScreenInfoPtr screen;

static void logEvent(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(logFile, format, args);
    va_end(args);
    fputc('\n', logFile);
    fflush(logFile);
}

static void pointerEvent(int buttonMask, int x, int y, rfbClientPtr client) {
    logEvent("pointer %d %d %d", buttonMask, x, y);
    rfbDefaultPtrAddEvent(buttonMask, x, y, client);
}

static void keyEvent(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    logEvent("key %s 0x%04x", down ? "down" : "up", (unsigned)key);
}

static void cutText(char *text, int length, rfbClientPtr client) {
    logEvent("cut %.*s", length, text);
}

static void clientGone(rfbClientPtr client) {
    logEvent("client gone");
}

static enum rfbNewClientAction newClient(rfbClientPtr client) {
    logEvent("client connected");
    /* The library calls this hook unconditionally when a client leaves; a NULL here is
     * a segfault on the first disconnect. */
    client->clientGoneHook = clientGone;
    return RFB_CLIENT_ACCEPT;
}

static void fillPattern(void) {
    unsigned char *fb = (unsigned char *)screen->frameBuffer;
    for (int y = 0; y < screen->height; y++) {
        for (int x = 0; x < screen->width; x++) {
            unsigned char *p = fb + (y * screen->width + x) * 4;
            p[0] = x & 255;        /* red   */
            p[1] = y & 255;        /* green */
            p[2] = (x ^ y) & 255;  /* blue  */
            p[3] = 0;
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <port> <log> [password]\n", argv[0]); return 2; }
    int port = atoi(argv[1]);
    logFile = fopen(argv[2], "a");
    if (!logFile) { perror("log"); return 2; }

    screen = rfbGetScreen(&argc, argv, 320, 200, 8, 3, 4);
    screen->desktopName = "SuperTerminal test desktop";
    screen->frameBuffer = malloc(320 * 200 * 4);
    screen->port = port;
    screen->ipv6port = 0;
    screen->listenInterface = htonl(INADDR_LOOPBACK);
    screen->alwaysShared = TRUE;
    screen->ptrAddEvent = pointerEvent;
    screen->kbdAddEvent = keyEvent;
    screen->setXCutText = cutText;
    screen->newClientHook = newClient;
    /* 32bpp, red at bit 0 like the pattern above; the client asks for its own format
     * and the server converts, which is exactly what a real server does. */
    screen->serverFormat.redShift = 0;
    screen->serverFormat.greenShift = 8;
    screen->serverFormat.blueShift = 16;
    screen->serverFormat.redMax = screen->serverFormat.greenMax = screen->serverFormat.blueMax = 255;
    if (argc > 3 && argv[3][0]) {
        static char *passwords[2];
        passwords[0] = argv[3];
        passwords[1] = NULL;
        screen->authPasswdData = passwords;
        screen->passwordCheck = rfbCheckPasswordByList;
    }
    fillPattern();
    rfbInitServer(screen);
    logEvent("listening %d", screen->port);

    int toggle = 0;
    long elapsed = 0;
    while (rfbIsActive(screen)) {
        rfbProcessEvents(screen, 50000);
        elapsed += 50;
        if (elapsed >= 500) {
            elapsed = 0;
            toggle = !toggle;
            unsigned char *fb = (unsigned char *)screen->frameBuffer;
            for (int y = 80; y < 120; y++)
                for (int x = 100; x < 140; x++) {
                    unsigned char *p = fb + (y * 320 + x) * 4;
                    p[0] = p[1] = p[2] = toggle ? 255 : 0;
                }
            rfbMarkRectAsModified(screen, 100, 80, 140, 120);
        }
    }
    return 0;
}
