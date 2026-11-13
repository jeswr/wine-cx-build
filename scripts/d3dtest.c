/* Tells which Direct3D 11 a program gets under Wine. Used by test-split.sh.
 * Prints where d3d11.dll and dxgi.dll were loaded from and whether DXMT's
 * helper (winemetal.dll) or Wine's own renderer (wined3d.dll) came with them.
 * With the argument "device" it also tries to create a Direct3D 11 device. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static void where(const char *name)
{
    char path[MAX_PATH] = "(not loaded)";
    HMODULE m = GetModuleHandleA(name);
    if (m) GetModuleFileNameA(m, path, sizeof(path));
    printf("%s: %s\n", name, path);
}

typedef HRESULT (WINAPI *create_device_t)(void *, int, HMODULE, UINT, const int *, UINT, UINT,
                                          void **, int *, void **);

int main(int argc, char **argv)
{
    HMODULE d3d11 = LoadLibraryA("d3d11.dll");
    if (!d3d11)
    {
        printf("d3d11.dll: load failed, error %lu\n", GetLastError());
        return 2;
    }
    where("d3d11.dll");
    where("dxgi.dll");
    where("winemetal.dll");
    where("wined3d.dll");
    fflush(stdout);
    if (argc > 1 && !strcmp(argv[1], "device"))
    {
        void *device = NULL, *context = NULL;
        int level = 0;
        create_device_t create = (create_device_t)GetProcAddress(d3d11, "D3D11CreateDevice");
        HRESULT hr = create ? create(NULL, 1 /* hardware */, NULL, 0, NULL, 0, 7, &device, &level, &context)
                            : E_NOINTERFACE;
        printf("device: hr=0x%08lx level=0x%x\n", (unsigned long)hr, level);
        fflush(stdout);
    }
    return 0;
}
