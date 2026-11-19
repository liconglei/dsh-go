#include "clipboard_channel.h"

#include <flutter/flutter_engine.h>

#include <windows.h>
#include <shlobj.h>

#include <gdiplus.h>

#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <string>
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

std::string Utf8FromWide(const std::wstring& value) {
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string out(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                        out.data(), length, nullptr, nullptr);
  return out;
}

std::wstring WideFromUtf8(const std::string& value) {
  const int length = ::MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0);
  if (length <= 0) return {};
  std::wstring out(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                        out.data(), length);
  return out;
}

std::wstring SafeFileName(const std::wstring& name) {
  std::wstring out;
  for (const wchar_t c : name) {
    switch (c) {
      case L'\\': case L'/': case L':': case L'*': case L'?':
      case L'"': case L'<': case L'>': case L'|':
        out += L'_';
        break;
      default:
        if (c >= 0 && c < 32) {
          out += L'_';
        } else {
          out += c;
        }
    }
  }
  if (out.empty()) out = L"image";
  return out;
}

// Saves PNG bytes under Pictures/DSH Go, returning the absolute path. No
// album or MediaStore concept on Windows; the file is the reply to the user.
bool SavePngToPictures(const std::vector<uint8_t>& bytes,
                       const std::wstring& name, std::wstring& out_path) {
  if (bytes.empty()) return false;
  wchar_t* pictures = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_Pictures, 0, nullptr, &pictures))) {
    return false;
  }
  const std::wstring dir = std::wstring(pictures) + L"\\DSH Go";
  ::CoTaskMemFree(pictures);
  if (!::CreateDirectoryW(dir.c_str(), nullptr) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }

  // Avoid overwriting an existing file: append a counter before the suffix.
  std::wstring base = SafeFileName(name);
  const size_t dot = base.rfind(L'.');
  const std::wstring stem = dot == std::wstring::npos ? base : base.substr(0, dot);
  const std::wstring ext = dot == std::wstring::npos ? L".png" : base.substr(dot);
  std::wstring path = dir + L"\\" + stem + ext;
  for (int n = 1; ::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES && n < 1000; ++n) {
    path = dir + L"\\" + stem + L" (" + std::to_wstring(n) + L")" + ext;
  }

  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const BOOL ok = ::WriteFile(file, bytes.data(),
                              static_cast<DWORD>(bytes.size()), &written, nullptr);
  ::CloseHandle(file);
  if (!ok || written != bytes.size()) {
    ::DeleteFileW(path.c_str());
    return false;
  }
  out_path = path;
  return true;
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
        if (call.method_name() == "saveImagePng") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          const std::vector<uint8_t>* bytes_value = nullptr;
          if (args != nullptr) {
            const auto bytes_it = args->find(flutter::EncodableValue("bytes"));
            if (bytes_it != args->end()) {
              bytes_value = std::get_if<std::vector<uint8_t>>(&bytes_it->second);
            }
          }
          if (bytes_value == nullptr) {
            result->Error("invalidArgs");
            return;
          }
          std::wstring name = L"image.png";
          const auto name_it = args->find(flutter::EncodableValue("name"));
          if (name_it != args->end()) {
            if (const auto* n = std::get_if<std::string>(&name_it->second)) {
              name = WideFromUtf8(*n);
            }
          }
          std::wstring path;
          if (!SavePngToPictures(*bytes_value, name, path)) {
            result->Error("saveFailed");
            return;
          }
          result->Success(flutter::EncodableValue(Utf8FromWide(path)));
          return;
        }

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
