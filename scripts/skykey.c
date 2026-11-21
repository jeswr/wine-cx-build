/* Presses a key for the Windows program in front, inside Wine: what the
 * launcher's pause hotkey uses to open the game's own pause menu before it
 * freezes the game.
 *
 *   skykey.exe [esc|enter|p]      (default esc)
 *
 * Prints the title of the window that was in front, and "sent N" (the number
 * of key events Windows took). */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    WORD vk = VK_ESCAPE;
    INPUT in[2];
    char title[256] = "";
    HWND fg = GetForegroundWindow();
    UINT sent;

    if (argc > 1)
    {
        if (!_stricmp(argv[1], "enter")) vk = VK_RETURN;
        else if (!_stricmp(argv[1], "p")) vk = 'P';
        else if (_stricmp(argv[1], "esc")) { printf("unknown key %s\n", argv[1]); return 2; }
    }
    if (fg) GetWindowTextA(fg, title, sizeof(title));
    printf("front: %s\n", fg ? title : "(none)");
    memset(in, 0, sizeof(in));
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = vk;
    in[0].ki.wScan = (WORD)MapVirtualKeyA(vk, MAPVK_VK_TO_VSC);
    in[1] = in[0];
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    sent = SendInput(1, &in[0], sizeof(INPUT));
    Sleep(60);   /* a held key for a moment, as a person presses it */
    sent += SendInput(1, &in[1], sizeof(INPUT));
    printf("sent %u\n", sent);
    return sent == 2 ? 0 : 1;
}
