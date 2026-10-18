/*
 * Vinho — wrapper do steamwebhelper.exe
 *
 * No Wine para macOS, o CEF da Steam não consegue usar a GPU via D3D11
 * (ANGLE falha ao consultar o adaptador DXGI) e a janela fica preta.
 * As flags da Steam não chegam ao steamwebhelper, então este wrapper fica
 * no lugar dele, repassa todos os argumentos para o original renomeado
 * (steamwebhelper_vinho_orig.exe) e acrescenta:
 *   --disable-gpu     renderização por software (funciona no Wine)
 *   --single-process  evita o swapchain D3D11 do renderer e junta o
 *                     NetworkService (que falha TLS via winsock no Wine)
 *
 * Inspirado em notpop/steam-on-m1-wine (MIT) e ByMedion/macos-wine-steam.
 * Compilar: x86_64-w64-mingw32-gcc -municode -mwindows -Os -s -o steamwebhelper.exe wrapper.c
 */
#include <windows.h>
#include <wchar.h>

#define ORIGINAL L"steamwebhelper_vinho_orig.exe"
#define EXTRA    L" --disable-gpu --single-process"

/* Pula o argv[0] (com ou sem aspas) da linha de comando. */
static const wchar_t *skip_argv0(const wchar_t *cmd) {
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd == L'"') cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR args, int show) {
    (void)inst; (void)prev; (void)args; (void)show;

    wchar_t self[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 1;
    slash[1] = 0;

    wchar_t original[MAX_PATH];
    if (_snwprintf(original, MAX_PATH, L"%ls%ls", self, ORIGINAL) < 0) return 1;

    const wchar_t *rest = skip_argv0(GetCommandLineW());
    size_t len = wcslen(original) + wcslen(rest) + wcslen(EXTRA) + 8;
    wchar_t *cmd = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, len * sizeof(wchar_t));
    if (!cmd) return 1;
    _snwprintf(cmd, len, L"\"%ls\" %ls%ls", original, rest, EXTRA);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);

    if (!CreateProcessW(original, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
