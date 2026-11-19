#ifndef RUNNER_WINDOW_GEOMETRY_H_
#define RUNNER_WINDOW_GEOMETRY_H_

#include <windows.h>

struct Geometry {
  int x = 10;
  int y = 10;
  int width = 1280;
  int height = 720;
  bool maximized = false;
};

// Reads the saved geometry, falling back to defaults and dropping anything
// that no longer fits a visible monitor.
Geometry ReadGeometry();

// Best-effort write; a locked-down profile must never break the app.
void WriteGeometry(HWND window);

#endif  // RUNNER_WINDOW_GEOMETRY_H_
