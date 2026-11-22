/* cefwrap.exe: a test stand-in for Steam's browser program (steamwebhelper.exe),
 * used only by scripts/steamtest.sh on GitHub's Macs. steamtest renames the real
 * program to steamwebhelper_real.exe, puts this in its place, and writes extra
 * Chromium options (one line, may be empty) to steamwebhelper_flags.txt beside it.
 * This starts the real program with Steam's own options plus those, waits for it
 * and returns its exit code. Each start is logged to steamwebhelper_wrap.log.
 * Build: x86_64-w64-mingw32-gcc -O1 -municode -o cefwrap.exe scripts/cefwrap.c */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static void dir_of_self(wchar_t *out, size_t n)
{
    wchar_t *slash;
    GetModuleFileNameW(NULL, out, (DWORD)n);
    slash = wcsrchr(out, L'\\');
    if (slash) slash[1] = 0; else out[0] = 0;
}

/* the command line without the program's own name */
static const wchar_t *after_program(const wchar_t *cl)
{
    if (*cl == L'"') {
        cl++;
        while (*cl && *cl != L'"') cl++;
        if (*cl) cl++;
    } else {
        while (*cl && *cl != L' ' && *cl != L'\t') cl++;
    }
    return cl;   /* starts with the space before the first option, or is empty */
}

int wmain(void)
{
    wchar_t dir[MAX_PATH], real[MAX_PATH], flagsf[MAX_PATH], logf[MAX_PATH], flags[2048] = L"";
    static wchar_t cmd[32768];
    const wchar_t *rest = after_program(GetCommandLineW());
    STARTUPINFOW si = { sizeof si };
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    FILE *f;

    dir_of_self(dir, MAX_PATH);
    swprintf(real, MAX_PATH, L"%lssteamwebhelper_real.exe", dir);
    swprintf(flagsf, MAX_PATH, L"%lssteamwebhelper_flags.txt", dir);
    swprintf(logf, MAX_PATH, L"%lssteamwebhelper_wrap.log", dir);

    if ((f = _wfopen(flagsf, L"r"))) {
        if (fgetws(flags, 2047, f)) {
            size_t n = wcslen(flags);
            while (n && (flags[n - 1] == L'\n' || flags[n - 1] == L'\r' || flags[n - 1] == L' ')) flags[--n] = 0;
        }
        fclose(f);
    }
    /* Chromium's child processes are started by the browser process from its own
     * file (steamwebhelper_real.exe), so only the browser process comes through
     * here; the options go after Steam's own */
    swprintf(cmd, 32768, L"\"%ls\"%ls%ls%ls", real, rest, flags[0] ? L" " : L"", flags);

    if ((f = _wfopen(logf, L"a"))) {
        SYSTEMTIME t;
        GetLocalTime(&t);
        fwprintf(f, L"%02d:%02d:%02d start, added [%ls], options: %.300ls\n", t.wHour, t.wMinute, t.wSecond, flags, rest);
        fclose(f);
    }
    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        if ((f = _wfopen(logf, L"a"))) { fwprintf(f, L"could not start the real helper: error %lu\n", GetLastError()); fclose(f); }
        return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    if ((f = _wfopen(logf, L"a"))) { fwprintf(f, L"helper ended with %lu\n", code); fclose(f); }
    return (int)code;
}
