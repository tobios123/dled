#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(768, 1024);
  if (!window.Create(L"DLED", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Same drawing area as the reference app (its screens are 768 x 1024), so
  // both can be compared at the same scale: Create() sizes the whole window
  // including title bar and borders; make the inside exactly 768 x 1024
  // (times the display scaling, like every Flutter size).
  {
    HWND hwnd = window.GetHandle();
    const UINT dpi = ::GetDpiForWindow(hwnd);
    RECT r{0, 0, ::MulDiv(768, dpi, 96), ::MulDiv(1024, dpi, 96)};
    ::AdjustWindowRectExForDpi(&r, static_cast<DWORD>(::GetWindowLongPtr(hwnd, GWL_STYLE)), FALSE,
                               static_cast<DWORD>(::GetWindowLongPtr(hwnd, GWL_EXSTYLE)), dpi);
    ::SetWindowPos(hwnd, nullptr, 0, 0, r.right - r.left, r.bottom - r.top,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
