#include "window_geometry.h"

#include <shlobj.h>

#include <string>

namespace {

std::wstring GeometryPath() {
  wchar_t* appdata = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &appdata))) {
    return {};
  }
  const std::wstring dir = std::wstring(appdata) + L"\\DSH Go";
  ::CoTaskMemFree(appdata);
  ::CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\window.ini";
}

}  // namespace

Geometry ReadGeometry() {
  Geometry g;
  const std::wstring path = GeometryPath();
  if (path.empty()) return g;
  g.x = ::GetPrivateProfileIntW(L"Window", L"x", g.x, path.c_str());
  g.y = ::GetPrivateProfileIntW(L"Window", L"y", g.y, path.c_str());
  const int width = ::GetPrivateProfileIntW(L"Window", L"width", g.width, path.c_str());
  const int height = ::GetPrivateProfileIntW(L"Window", L"height", g.height, path.c_str());
  if (width >= 640 && height >= 480) {
    g.width = width;
    g.height = height;
  }
  g.maximized = ::GetPrivateProfileIntW(L"Window", L"maximized", 0, path.c_str()) != 0;

  // A resolution change or undocked monitor must not start the window offscreen.
  RECT workarea{};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &workarea, 0);
  if (g.x < workarea.left - 8 || g.y < workarea.top - 8 ||
      g.x > workarea.right - 64 || g.y > workarea.bottom - 64) {
    g.x = 10;
    g.y = 10;
  }
  return g;
}

void WriteGeometry(HWND window) {
  const std::wstring path = GeometryPath();
  if (path.empty() || !::IsWindow(window)) return;
  // A minimised window reports SW_SHOWMINIMIZED; writing it would forget that
  // the window was maximised before it went to the tray.
  if (::IsIconic(window)) return;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement)) return;
  const RECT& rect = placement.rcNormalPosition;
  ::WritePrivateProfileStringW(L"Window", L"x",
                               std::to_wstring(rect.left).c_str(), path.c_str());
  ::WritePrivateProfileStringW(L"Window", L"y",
                               std::to_wstring(rect.top).c_str(), path.c_str());
  ::WritePrivateProfileStringW(
      L"Window", L"width", std::to_wstring(rect.right - rect.left).c_str(), path.c_str());
  ::WritePrivateProfileStringW(
      L"Window", L"height", std::to_wstring(rect.bottom - rect.top).c_str(), path.c_str());
  ::WritePrivateProfileStringW(
      L"Window", L"maximized",
      placement.showCmd == SW_SHOWMAXIMIZED ? L"1" : L"0", path.c_str());
}
