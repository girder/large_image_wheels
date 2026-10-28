/* launcher.c - stand-in for a command line tool bundled in a Windows wheel.
 *
 * The linux and macos wheels ship their bundled tools (tiffinfo, gdalinfo,
 * vips, ...) as <package>/bin/<tool> with an rpath to the wheel's library
 * directory, so the tool runs when invoked by path.  Windows has no rpath:
 * an .exe finds its DLLs in its own directory, the system directories and
 * PATH, and delvewheel keeps the bundled (name-mangled) DLLs in the
 * wheel's top-level <dist>.libs directory, two levels up from
 * <package>/bin.  The build therefore moves each real tool into
 * <dist>.libs, next to its DLLs (and next to the vcruntime140.dll the tools
 * need and python's own directory would otherwise have to supply), and
 * installs this launcher under the tool's name in <package>/bin.  The
 * launcher finds <dist>.libs relative to its own location, puts it first on
 * PATH, runs the tool there with the unchanged command line and the
 * inherited console, and exits with the tool's exit status.  Nothing is
 * duplicated; the real tool is a normal executable in a directory that is
 * self-sufficient.
 *
 * The launcher is built without the C runtime (kernel32 only, static
 * buffers, no optimizer so no memset/memcpy intrinsics are introduced):
 *
 *   cl /nologo /Od /GS- /W4 /DLIW_LIBS_NAME=pylibtiff.libs /c launcher.c
 *   link /nologo /NODEFAULTLIB /ENTRY:entry /SUBSYSTEM:CONSOLE
 *        /OUT:launcher.exe launcher.obj kernel32.lib
 *
 * LIW_LIBS_NAME is the name of the wheel's library directory (a bare
 * token, stringified here, because quotes do not survive a PowerShell
 * native command line); LIW_LIBS_UP (default 2) is how many directories
 * above the launcher's own directory that directory's parent is
 * (<site-packages>/<package>/bin -> 2).
 */

#include <windows.h>

#ifndef LIW_LIBS_NAME
#error LIW_LIBS_NAME must be defined (the wheel's library directory name)
#endif
#ifndef LIW_LIBS_UP
#define LIW_LIBS_UP 2
#endif
#define LIW_STR2(x) #x
#define LIW_STR(x) LIW_STR2(x)
#define LIW_WIDE2(s) L ## s
#define LIW_WIDE(s) LIW_WIDE2(s)
#define LIW_LIBS_DIR LIW_WIDE(LIW_STR(LIW_LIBS_NAME))

#define BUF 32768

static wchar_t self[BUF];
static wchar_t target[BUF];
static wchar_t libs[BUF];
static wchar_t oldpath[BUF];
static wchar_t newpath[2 * BUF];
static char narrow[BUF];
static STARTUPINFOW si;
static PROCESS_INFORMATION pi;

static DWORD wlen(const wchar_t *s)
{
    DWORD n = 0;
    while (s[n]) {
        n++;
    }
    return n;
}

static void wcat(wchar_t *dest, DWORD *pos, const wchar_t *src)
{
    while (*src) {
        dest[(*pos)++] = *src++;
    }
    dest[*pos] = 0;
}

static void say(const wchar_t *text)
{
    HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    DWORD written = 0;
    int n;
    if (err == INVALID_HANDLE_VALUE || err == NULL) {
        return;
    }
    if (WriteConsoleW(err, text, wlen(text), &written, NULL)) {
        return;
    }
    /* Redirected stderr: write the text as bytes in the ANSI code page. */
    n = WideCharToMultiByte(CP_ACP, 0, text, -1, narrow, BUF, NULL, NULL);
    if (n > 1) {
        WriteFile(err, narrow, (DWORD)(n - 1), &written, NULL);
    }
}

static void fail(const wchar_t *what, const wchar_t *detail)
{
    say(L"launcher: ");
    say(what);
    if (detail) {
        say(L": ");
        say(detail);
    }
    say(L"\r\n");
    ExitProcess(127);
}

void entry(void)
{
    DWORD n, pos, code = 127, up;
    const wchar_t *name;
    BYTE *p;
    DWORD i;

    n = GetModuleFileNameW(NULL, self, BUF);
    if (n == 0 || n >= BUF - 1) {
        fail(L"cannot determine my own path", NULL);
    }
    /* name = the launcher's own file name; cut LIW_LIBS_UP + 1 path
     * components off to reach the directory that holds LIW_LIBS_DIR. */
    while (n > 0 && self[n - 1] != L'\\' && self[n - 1] != L'/') {
        n--;
    }
    name = self + n;
    for (up = 0; up <= LIW_LIBS_UP; up++) {
        while (n > 0 && (self[n - 1] == L'\\' || self[n - 1] == L'/')) {
            n--;
        }
        if (up == LIW_LIBS_UP) {
            break;
        }
        while (n > 0 && self[n - 1] != L'\\' && self[n - 1] != L'/') {
            n--;
        }
    }
    if (n == 0) {
        fail(L"my path is too shallow to locate the library directory", self);
    }
    pos = 0;
    for (i = 0; i < n; i++) {
        libs[pos++] = self[i];
    }
    libs[pos] = 0;
    wcat(libs, &pos, L"\\");
    wcat(libs, &pos, LIW_LIBS_DIR);
    pos = 0;
    wcat(target, &pos, libs);
    wcat(target, &pos, L"\\");
    wcat(target, &pos, name);
    if (GetFileAttributesW(target) == INVALID_FILE_ATTRIBUTES) {
        fail(L"bundled tool not found", target);
    }

    pos = 0;
    wcat(newpath, &pos, libs);
    n = GetEnvironmentVariableW(L"PATH", oldpath, BUF);
    if (n > 0 && n < BUF) {
        wcat(newpath, &pos, L";");
        wcat(newpath, &pos, oldpath);
    }
    if (!SetEnvironmentVariableW(L"PATH", newpath)) {
        fail(L"cannot set PATH", NULL);
    }

    /* Ctrl-C goes to the tool (same console); the launcher ignores it and
     * reports the tool's exit status. */
    SetConsoleCtrlHandler(NULL, TRUE);

    p = (BYTE *)&si;
    for (i = 0; i < sizeof(si); i++) {
        p[i] = 0;
    }
    si.cb = sizeof(si);
    if (!CreateProcessW(target, GetCommandLineW(), NULL, NULL, TRUE, 0,
                        NULL, NULL, &si, &pi)) {
        fail(L"cannot start bundled tool", target);
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    if (!GetExitCodeProcess(pi.hProcess, &code)) {
        code = 127;
    }
    CloseHandle(pi.hProcess);
    ExitProcess(code);
}
