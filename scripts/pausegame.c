/* A stand-in for the game in the cloud checks of "skywalker.sh pause": a
 * window that draws with Direct3D 11 every frame (or GDI if no device can be
 * made), keeps a sound playing through waveOut, and writes what it sees to two
 * files so that a check can tell whether it was frozen and whether it came back.
 *
 *   pausegame.exe HEARTBEAT EVENTS [WIDTH HEIGHT]
 *
 * HEARTBEAT is rewritten 4 times a second with one line:
 *   frames=N presents_ok=N audio=N tick=MS maxgap=MS d3d=0|1 active=0|1
 *   (audio = sound buffers played so far, maxgap = the longest time between two frames)
 * EVENTS gets one line per window message of interest (activation, end of
 * session, close, display change, size), with the tick it arrived at. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static const char *events_path;
static int active;
static volatile int quitting;

static void event_line(const char *fmt, ...)
{
    FILE *f = fopen(events_path, "a");
    va_list ap;
    if (!f) return;
    fprintf(f, "%llu ", (unsigned long long)GetTickCount64());
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_ACTIVATEAPP:
        active = wp ? 1 : 0;
        event_line("activateapp %d", active);
        break;
    case WM_ACTIVATE:
        event_line("activate %d", (int)LOWORD(wp));
        break;
    case WM_QUERYENDSESSION:
        event_line("queryendsession lp=0x%lx", (unsigned long)lp);
        return TRUE;   /* what most games answer */
    case WM_ENDSESSION:
        event_line("endsession %d", (int)wp);
        if (wp) quitting = 1;
        return 0;
    case WM_CLOSE:
        event_line("close");
        quitting = 1;
        return 0;
    case WM_DISPLAYCHANGE:
        event_line("displaychange %dx%d", (int)LOWORD(lp), (int)HIWORD(lp));
        break;
    case WM_SIZE:
        event_line("size %dx%d type=%d", (int)LOWORD(lp), (int)HIWORD(lp), (int)wp);
        break;
    case WM_DESTROY:
        quitting = 1;
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

#define AUDIO_BUFS 3
#define AUDIO_SAMPLES 4410   /* 100 ms at 44.1 kHz */

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    const char *heartbeat_path;
    int w = 800, h = 600, i, d3d = 0;
    WNDCLASSA wc = {0};
    HWND hwnd;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *chain = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    DXGI_SWAP_CHAIN_DESC sd = {0};
    HWAVEOUT wo = NULL;
    WAVEHDR hdr[AUDIO_BUFS];
    static short pcm[AUDIO_BUFS][AUDIO_SAMPLES];
    unsigned long long frames = 0, presents_ok = 0, audio = 0, last_frame, last_beat = 0, maxgap = 0, now;

    (void)prev; (void)cmd; (void)show;
    if (__argc < 3)
    {
        MessageBoxA(NULL, "usage: pausegame.exe HEARTBEAT EVENTS [W H]", "pausegame", 0);
        return 2;
    }
    heartbeat_path = __argv[1];
    events_path = __argv[2];
    if (__argc >= 5) { w = atoi(__argv[3]); h = atoi(__argv[4]); }

    wc.lpfnWndProc = proc;
    wc.hInstance = inst;
    wc.lpszClassName = "FAKEGAME";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    RegisterClassA(&wc);
    hwnd = CreateWindowExA(0, "FAKEGAME", "FAKEGAME stand-in", WS_POPUP | WS_VISIBLE, 0, 0, w, h,
                           NULL, NULL, inst, NULL);
    if (!hwnd) return 3;
    SetForegroundWindow(hwnd);

    sd.BufferCount = 2;
    sd.BufferDesc.Width = w;
    sd.BufferDesc.Height = h;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    if (SUCCEEDED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                                D3D11_SDK_VERSION, &sd, &chain, &dev, NULL, &ctx)))
    {
        ID3D11Texture2D *back = NULL;
        if (SUCCEEDED(IDXGISwapChain_GetBuffer(chain, 0, &IID_ID3D11Texture2D, (void **)&back)))
        {
            if (SUCCEEDED(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv))) d3d = 1;
            ID3D11Texture2D_Release(back);
        }
    }
    event_line("start d3d=%d %dx%d", d3d, w, h);

    {
        WAVEFORMATEX fmt = {0};
        fmt.wFormatTag = WAVE_FORMAT_PCM;
        fmt.nChannels = 1;
        fmt.nSamplesPerSec = 44100;
        fmt.wBitsPerSample = 16;
        fmt.nBlockAlign = 2;
        fmt.nAvgBytesPerSec = 88200;
        for (i = 0; i < AUDIO_SAMPLES; i++)   /* a quiet 440 Hz tone */
            pcm[0][i] = pcm[1][i] = pcm[2][i] = (short)(800 * sin(i * 2 * 3.14159265 * 440 / 44100));
        if (waveOutOpen(&wo, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) == MMSYSERR_NOERROR)
        {
            for (i = 0; i < AUDIO_BUFS; i++)
            {
                memset(&hdr[i], 0, sizeof(hdr[i]));
                hdr[i].lpData = (LPSTR)pcm[i];
                hdr[i].dwBufferLength = sizeof(pcm[i]);
                waveOutPrepareHeader(wo, &hdr[i], sizeof(hdr[i]));
                waveOutWrite(wo, &hdr[i], sizeof(hdr[i]));
            }
            event_line("audio open");
        }
        else
        {
            wo = NULL;
            event_line("audio none");
        }
    }

    last_frame = GetTickCount64();
    while (!quitting)
    {
        MSG m;
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE))
        {
            if (m.message == WM_QUIT) quitting = 1;
            TranslateMessage(&m);
            DispatchMessageA(&m);
        }
        if (quitting) break;
        if (wo)
            for (i = 0; i < AUDIO_BUFS; i++)
                if (hdr[i].dwFlags & WHDR_DONE)
                {
                    audio++;
                    waveOutWrite(wo, &hdr[i], sizeof(hdr[i]));
                }
        if (d3d)
        {
            float c[4] = { (frames % 120) / 120.0f, 0.3f, 0.6f, 1.0f };
            ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
            if (SUCCEEDED(IDXGISwapChain_Present(chain, 1, 0))) presents_ok++;
        }
        else
        {
            HDC dc = GetDC(hwnd);
            RECT r = { 0, 0, w, h };
            HBRUSH b = CreateSolidBrush(RGB(frames % 256, 80, 160));
            FillRect(dc, &r, b);
            DeleteObject(b);
            ReleaseDC(hwnd, dc);
            Sleep(16);
        }
        frames++;
        now = GetTickCount64();
        if (now - last_frame > maxgap) maxgap = now - last_frame;
        last_frame = now;
        if (now - last_beat >= 250)
        {
            FILE *f = fopen(heartbeat_path, "w");
            if (f)
            {
                fprintf(f, "frames=%llu presents_ok=%llu audio=%llu tick=%llu maxgap=%llu d3d=%d active=%d\n",
                        frames, presents_ok, audio, now, maxgap, d3d, active);
                fclose(f);
            }
            last_beat = now;
        }
    }
    event_line("exit frames=%llu maxgap=%llu", frames, maxgap);
    if (wo) { waveOutReset(wo); waveOutClose(wo); }
    return 0;
}
