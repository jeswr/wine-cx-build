/* skyfit: fits a running game's window to the main screen, from outside the game.
 *
 * Used by skywalker.sh when the Mac's screens change while the game runs (a
 * monitor or projector plugged in or out, mirroring switched, the resolution
 * changed). The game runs in a borderless window that covers the screen; when
 * the screen changes, Windows (and Wine) leave that window where it was, so it
 * no longer fits. This finds the largest visible window of the game's process
 * and moves and sizes it to cover the main ("primary") monitor as Wine now
 * sees it. Windows then sends the game the usual "you were resized" message,
 * which is what a game with a borderless window acts on.
 *
 *   skyfit.exe [name]           fit the largest window of the first process whose
 *                               program name contains "name" (default: SKYWALKERSAGA)
 *   skyfit.exe --show [name]    only print what would be done
 *   skyfit.exe --monitor        print the main monitor as Wine sees it
 *   skyfit.exe --test-window S  a stand-in game for the cloud test: a borderless
 *                               window covering the main monitor, which prints
 *                               every resize and screen change for S seconds
 *
 * Exit codes: 0 fitted (or already fitting), 3 no such window, 4 failed. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

static const char *want = "SKYWALKERSAGA";
static HWND best;
static LONG best_area;
static DWORD best_pid;
static char best_exe[MAX_PATH];

static void upper(char *s) { for (; *s; s++) *s = (char)toupper((unsigned char)*s); }

static BOOL program_of(DWORD pid, char *out, DWORD size)
{
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    BOOL ok;
    if (!h) return FALSE;
    ok = QueryFullProcessImageNameA(h, 0, out, &size);
    CloseHandle(h);
    return ok;
}

static BOOL CALLBACK each_window(HWND hwnd, LPARAM unused)
{
    DWORD pid = 0;
    RECT r;
    LONG area;
    char exe[MAX_PATH], name[MAX_PATH];
    const char *base;

    (void)unused;
    if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER)) return TRUE;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == GetCurrentProcessId() || !program_of(pid, exe, sizeof(exe))) return TRUE;
    base = strrchr(exe, '\\');
    base = base ? base + 1 : exe;
    lstrcpynA(name, base, sizeof(name));
    upper(name);
    if (!strstr(name, want)) return TRUE;
    if (!GetWindowRect(hwnd, &r)) return TRUE;
    area = (r.right - r.left) * (r.bottom - r.top);
    if (!best || area > best_area)
    {
        best = hwnd;
        best_area = area;
        best_pid = pid;
        lstrcpynA(best_exe, base, sizeof(best_exe));
    }
    return TRUE;
}

static RECT main_monitor(void)
{
    POINT origin = {0, 0};
    MONITORINFO mi;
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoA(MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY), &mi))
    {
        SetRect(&mi.rcMonitor, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    }
    return mi.rcMonitor;
}

static void print_rect(const char *what, const RECT *r)
{
    printf("%s %ldx%ld at %ld,%ld\n", what, r->right - r->left, r->bottom - r->top, r->left, r->top);
}

/* ---------------------------------------------------------------- stand-in game */

static LRESULT CALLBACK test_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_SIZE:
        printf("test-window: WM_SIZE %ux%u\n", LOWORD(lp), HIWORD(lp));
        fflush(stdout);
        return 0;
    case WM_DISPLAYCHANGE:
        printf("test-window: WM_DISPLAYCHANGE %ux%u\n", LOWORD(lp), HIWORD(lp));
        fflush(stdout);
        return 0;
    case WM_ERASEBKGND:
    {
        RECT r;
        GetClientRect(hwnd, &r);
        FillRect((HDC)wp, &r, (HBRUSH)GetStockObject(BLACK_BRUSH));
        return 1;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static int test_window(int seconds)
{
    WNDCLASSA wc;
    RECT m = main_monitor();
    HWND hwnd;
    MSG msg;
    DWORD end = GetTickCount() + (DWORD)seconds * 1000;

    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = test_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "skyfit-test";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    RegisterClassA(&wc);
    print_rect("test-window: monitor", &m);
    hwnd = CreateWindowExA(0, "skyfit-test", "skyfit test window", WS_POPUP | WS_VISIBLE,
                           m.left, m.top, m.right - m.left, m.bottom - m.top,
                           NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("test-window: CreateWindow failed %lu\n", GetLastError()); return 4; }
    fflush(stdout);
    SetTimer(hwnd, 1, 250, NULL);
    while (GetTickCount() < end && GetMessageA(&msg, NULL, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    printf("test-window: done\n");
    return 0;
}

/* ---------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    int show = 0, i = 1;
    RECT m, w;
    int mw, mh;

    if (argc > 1 && !strcmp(argv[1], "--test-window"))
        return test_window(argc > 2 ? atoi(argv[2]) : 60);
    if (argc > 1 && !strcmp(argv[1], "--monitor"))
    {
        m = main_monitor();
        print_rect("monitor", &m);
        return 0;
    }
    if (argc > i && !strcmp(argv[i], "--show")) { show = 1; i++; }
    if (argc > i)
    {
        static char buf[MAX_PATH];
        lstrcpynA(buf, argv[i], sizeof(buf));
        upper(buf);
        want = buf;
    }

    m = main_monitor();
    mw = m.right - m.left;
    mh = m.bottom - m.top;
    print_rect("monitor", &m);
    EnumWindows(each_window, 0);
    if (!best)
    {
        printf("window: none found for %s\n", want);
        return 3;
    }
    GetWindowRect(best, &w);
    printf("window: %s (process %lu) ", best_exe, best_pid);
    print_rect("is", &w);
    if (EqualRect(&w, &m))
    {
        printf("result: already fits\n");
        return 0;
    }
    if (show) return 0;
    if (!SetWindowPos(best, NULL, m.left, m.top, mw, mh,
                      SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_NOOWNERZORDER))
    {
        printf("result: SetWindowPos failed %lu\n", GetLastError());
        return 4;
    }
    Sleep(300);
    GetWindowRect(best, &w);
    print_rect("result: now", &w);
    return EqualRect(&w, &m) ? 0 : 4;
}
