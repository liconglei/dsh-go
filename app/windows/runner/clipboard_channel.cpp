#include "clipboard_channel.h"

#include <flutter/flutter_engine.h>

#include <windows.h>

#include <gdiplus.h>

#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <vector>

#pragma comment(lib, "gdiplus.lib")

namespace {

int GetEncoderClsid(const wchar_t* mime, CLSID* clsid) {
  UINT count = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  if (size == 0) return -1;
  auto* info = static_cast<Gdiplus::ImageCodecInfo*>(std::malloc(size));
  if (info == nullptr) return -1;
  Gdiplus::GetImageEncoders(count, size, info);
  int found = -1;
  for (UINT i = 0; i < count; ++i) {
    if (std::wcscmp(info[i].MimeType, mime) == 0) {
      *clsid = info[i].Clsid;
      found = static_cast<int>(i);
      break;
    }
  }
  std::free(info);
  return found;
}

bool TakePngFormat(std::vector<uint8_t>& out) {
  const UINT format = ::RegisterClipboardFormatW(L"PNG");
  if (format == 0 || !::IsClipboardFormatAvailable(format)) return false;
  if (!::OpenClipboard(nullptr)) return false;
  HGLOBAL handle = static_cast<HGLOBAL>(::GetClipboardData(format));
  if (handle == nullptr) {
    ::CloseClipboard();
    return false;
  }
  void* data = ::GlobalLock(handle);
  const SIZE_T size = ::GlobalSize(handle);
  if (data != nullptr && size > 0) {
    const auto* bytes = static_cast<const uint8_t*>(data);
    out.assign(bytes, bytes + size);
  }
  ::GlobalUnlock(handle);
  ::CloseClipboard();
  return !out.empty();
}

bool TakeDibAsPng(std::vector<uint8_t>& out) {
  if (!::IsClipboardFormatAvailable(CF_DIB) || !::OpenClipboard(nullptr)) return false;
  HGLOBAL handle = static_cast<HGLOBAL>(::GetClipboardData(CF_DIB));
  if (handle == nullptr) {
    ::CloseClipboard();
    return false;
  }
  auto* bmi = static_cast<BITMAPINFO*>(::GlobalLock(handle));
  const SIZE_T dibSize = ::GlobalSize(handle);
  if (bmi == nullptr || dibSize < sizeof(BITMAPINFOHEADER) ||
      bmi->bmiHeader.biWidth <= 0 || bmi->bmiHeader.biHeight == 0 ||
      bmi->bmiHeader.biHeight == LONG_MIN) {
    if (bmi != nullptr) ::GlobalUnlock(handle);
    ::CloseClipboard();
    return false;
  }

  DWORD colors = bmi->bmiHeader.biClrUsed;
  if (colors == 0 && bmi->bmiHeader.biBitCount <= 8) {
    colors = static_cast<DWORD>(1) << bmi->bmiHeader.biBitCount;
  }
  SIZE_T offset = bmi->bmiHeader.biSize + colors * sizeof(RGBQUAD);
  // A 40-byte header keeps BI_BITFIELDS masks after the header; V4/V5 already
  // contain them.
  if (bmi->bmiHeader.biCompression == BI_BITFIELDS &&
      bmi->bmiHeader.biSize == sizeof(BITMAPINFOHEADER)) {
    offset += 3 * sizeof(DWORD);
  }
  if (offset >= dibSize) {
    ::GlobalUnlock(handle);
    ::CloseClipboard();
    return false;
  }

  HDC screen = ::GetDC(nullptr);
  HBITMAP bitmap = ::CreateDIBitmap(screen, &bmi->bmiHeader, CBM_INIT,
                                    reinterpret_cast<BYTE*>(bmi) + offset,
                                    bmi, DIB_RGB_COLORS);
  ::ReleaseDC(nullptr, screen);
  ::GlobalUnlock(handle);
  ::CloseClipboard();
  if (bitmap == nullptr) return false;

  Gdiplus::GdiplusStartupInput startup;
  ULONG_PTR token = 0;
  if (Gdiplus::GdiplusStartup(&token, &startup, nullptr) != Gdiplus::Ok) {
    ::DeleteObject(bitmap);
    return false;
  }
  {
    Gdiplus::Bitmap image(bitmap, nullptr);
    IStream* stream = nullptr;
    CLSID png = {};
    if (::CreateStreamOnHGlobal(nullptr, TRUE, &stream) == S_OK &&
        GetEncoderClsid(L"image/png", &png) >= 0 &&
        image.Save(stream, &png) == Gdiplus::Ok) {
      HGLOBAL memory = nullptr;
      if (::GetHGlobalFromStream(stream, &memory) == S_OK && memory != nullptr) {
        void* data = ::GlobalLock(memory);
        const SIZE_T size = ::GlobalSize(memory);
        if (data != nullptr && size > 0) {
          const auto* bytes = static_cast<const uint8_t*>(data);
          out.assign(bytes, bytes + size);
        }
        ::GlobalUnlock(memory);
      }
    }
    if (stream != nullptr) stream->Release();
  }
  Gdiplus::GdiplusShutdown(token);
  ::DeleteObject(bitmap);
  return !out.empty();
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateClipboardChannel(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "dsh/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "imagePng") {
          result->NotImplemented();
          return;
        }
        std::vector<uint8_t> bytes;
        if (!TakePngFormat(bytes)) bytes.clear();
        if (bytes.empty()) TakeDibAsPng(bytes);
        if (bytes.empty()) {
          result->Success(flutter::EncodableValue());
        } else {
          result->Success(flutter::EncodableValue(std::move(bytes)));
        }
      });
  return channel;
}
