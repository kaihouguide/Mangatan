#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

using FileSizeCallback = uint32_t (*)(const char* file_path);
using FileContentCallback = void (*)(const char* file_path,
                                     uint32_t buffer_size,
                                     char* buffer);
using SetFileContentFunctionsFn =
    void (*)(FileSizeCallback file_size, FileContentCallback file_content);
using InitOCRUsingCallbackFn = bool (*)();
using PerformOCRFn = char* (*)(const void* bitmap, uint32_t* annotation_length);
using FreeLibraryAllocatedCharArrayFn = void (*)(char* buffer);
using UninitializeOCRFn = void (*)();

std::wstring g_component_dir;
HMODULE g_screen_ai = nullptr;
SetFileContentFunctionsFn g_set_file_content_functions = nullptr;
InitOCRUsingCallbackFn g_init_ocr = nullptr;
PerformOCRFn g_perform_ocr = nullptr;
FreeLibraryAllocatedCharArrayFn g_free_char_array = nullptr;
UninitializeOCRFn g_uninitialize_ocr = nullptr;
bool g_initialized = false;

std::wstring Utf8ToWide(const char* value) {
  if (!value || !*value) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value, -1, nullptr, 0);
  if (size <= 1) {
    return std::wstring();
  }
  std::wstring result(size - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value, -1, result.data(), size);
  return result;
}

std::wstring JoinPath(const std::wstring& base, const std::wstring& relative) {
  std::wstring normalized = relative;
  std::replace(normalized.begin(), normalized.end(), L'/', L'\\');
  while (!normalized.empty() &&
         (normalized.front() == L'\\' || normalized.front() == L'/')) {
    normalized.erase(normalized.begin());
  }
  if (base.empty()) {
    return normalized;
  }
  if (base.back() == L'\\' || base.back() == L'/') {
    return base + normalized;
  }
  return base + L"\\" + normalized;
}

bool IsSafeRelativePath(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  if (path.find(L":") != std::wstring::npos) {
    return false;
  }
  if (path.find(L"..") != std::wstring::npos) {
    return false;
  }
  return true;
}

uint32_t ScreenAiFileSize(const char* file_path) {
  const auto relative = Utf8ToWide(file_path);
  if (!IsSafeRelativePath(relative)) {
    return 0;
  }
  const auto full_path = JoinPath(g_component_dir, relative);
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExW(full_path.c_str(), GetFileExInfoStandard, &data)) {
    return 0;
  }
  if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
    return 0;
  }
  ULARGE_INTEGER size;
  size.HighPart = data.nFileSizeHigh;
  size.LowPart = data.nFileSizeLow;
  return size.QuadPart > UINT32_MAX ? 0 : static_cast<uint32_t>(size.QuadPart);
}

void ScreenAiFileContent(const char* file_path,
                         uint32_t buffer_size,
                         char* buffer) {
  if (!buffer || buffer_size == 0) {
    return;
  }
  const auto relative = Utf8ToWide(file_path);
  if (!IsSafeRelativePath(relative)) {
    return;
  }
  const auto full_path = JoinPath(g_component_dir, relative);
  HANDLE file = CreateFileW(full_path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD read = 0;
  ReadFile(file, buffer, buffer_size, &read, nullptr);
  CloseHandle(file);
}

char* CopyCString(const char* text) {
  const size_t length = text ? std::strlen(text) : 0;
  auto* output = reinterpret_cast<char*>(CoTaskMemAlloc(length + 1));
  if (!output) {
    return nullptr;
  }
  if (length > 0) {
    std::memcpy(output, text, length);
  }
  output[length] = '\0';
  return output;
}

uint8_t* CopyBytes(const uint8_t* data, uint32_t length) {
  if (!data || length == 0) {
    return nullptr;
  }
  auto* output = reinterpret_cast<uint8_t*>(CoTaskMemAlloc(length));
  if (!output) {
    return nullptr;
  }
  std::memcpy(output, data, length);
  return output;
}

bool LoadScreenAi(const wchar_t* component_dir, char** error) {
  if (!component_dir || !*component_dir) {
    if (error) {
      *error = CopyCString("ScreenAI component path is empty");
    }
    return false;
  }
  if (g_initialized && g_component_dir == component_dir) {
    return true;
  }
  if (g_initialized && g_uninitialize_ocr) {
    g_uninitialize_ocr();
  }
  g_initialized = false;
  if (g_screen_ai) {
    FreeLibrary(g_screen_ai);
    g_screen_ai = nullptr;
  }

  g_component_dir = component_dir;
  const auto dll_path = JoinPath(g_component_dir, L"chrome_screen_ai.dll");
  g_screen_ai = LoadLibraryW(dll_path.c_str());
  if (!g_screen_ai) {
    if (error) {
      *error = CopyCString("Could not load chrome_screen_ai.dll");
    }
    return false;
  }

  g_set_file_content_functions =
      reinterpret_cast<SetFileContentFunctionsFn>(
          GetProcAddress(g_screen_ai, "SetFileContentFunctions"));
  g_init_ocr = reinterpret_cast<InitOCRUsingCallbackFn>(
      GetProcAddress(g_screen_ai, "InitOCRUsingCallback"));
  g_perform_ocr =
      reinterpret_cast<PerformOCRFn>(GetProcAddress(g_screen_ai, "PerformOCR"));
  g_free_char_array = reinterpret_cast<FreeLibraryAllocatedCharArrayFn>(
      GetProcAddress(g_screen_ai, "FreeLibraryAllocatedCharArray"));
  g_uninitialize_ocr = reinterpret_cast<UninitializeOCRFn>(
      GetProcAddress(g_screen_ai, "UninitializeOCR"));
  if (!g_set_file_content_functions || !g_init_ocr || !g_perform_ocr ||
      !g_free_char_array || !g_uninitialize_ocr) {
    if (error) {
      *error = CopyCString("ScreenAI DLL is missing required OCR exports");
    }
    return false;
  }

  g_set_file_content_functions(ScreenAiFileSize, ScreenAiFileContent);
  if (!g_init_ocr()) {
    if (error) {
      *error = CopyCString("ScreenAI OCR initialization failed");
    }
    return false;
  }
  g_initialized = true;
  return true;
}

void WritePointer(uint8_t* target, size_t offset, void* value) {
  *reinterpret_cast<uint64_t*>(target + offset) =
      reinterpret_cast<uint64_t>(value);
}

void WriteUint64(uint8_t* target, size_t offset, uint64_t value) {
  *reinterpret_cast<uint64_t*>(target + offset) = value;
}

void WriteInt32(uint8_t* target, size_t offset, int32_t value) {
  *reinterpret_cast<int32_t*>(target + offset) = value;
}

void WriteUint8(uint8_t* target, size_t offset, uint8_t value) {
  *(target + offset) = value;
}

void ScreenAiFreeUnchecked(void* pointer) {
  if (pointer) {
    CoTaskMemFree(pointer);
  }
}

}  // namespace

static int RecognizeUnchecked(const wchar_t* component_dir,
                              const uint8_t* rgba_pixels,
                              int32_t width,
                              int32_t height,
                              uint8_t** output,
                              uint32_t* output_length,
                              char** error) {
  if (output) {
    *output = nullptr;
  }
  if (output_length) {
    *output_length = 0;
  }
  if (error) {
    *error = nullptr;
  }
  if (!output || !output_length || !rgba_pixels || width <= 0 || height <= 0) {
    if (error) {
      *error = CopyCString("Invalid ScreenAI OCR input");
    }
    return 0;
  }
  if (!LoadScreenAi(component_dir, error)) {
    return 0;
  }

  const uint64_t row_bytes = static_cast<uint64_t>(width) * 4;
  const uint64_t pixel_count =
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4;
  std::vector<uint8_t> pixels(pixel_count);
  
  // Fast C++ byte swap from RGBA to BGRA
  for (size_t i = 0; i < pixel_count; i += 4) {
    pixels[i]     = rgba_pixels[i + 2]; // B
    pixels[i + 1] = rgba_pixels[i + 1]; // G
    pixels[i + 2] = rgba_pixels[i];     // R
    pixels[i + 3] = rgba_pixels[i + 3]; // A
  }

  uint8_t bitmap[56] = {};
  uint8_t pixel_ref[104] = {};
  uint8_t vtable[64] = {};
  WritePointer(bitmap, 0, pixel_ref);
  WritePointer(bitmap, 8, pixels.data());
  WriteUint64(bitmap, 16, row_bytes);
  WritePointer(bitmap, 24, nullptr);
  WriteInt32(bitmap, 32, 6);   // kBGRA_8888_SkColorType
  WriteInt32(bitmap, 36, 2);   // kPremul_SkAlphaType
  WriteInt32(bitmap, 40, width);
  WriteInt32(bitmap, 44, height);
  WriteUint8(bitmap, 48, 0);

  WritePointer(pixel_ref, 0, vtable);
  WriteInt32(pixel_ref, 8, 1);
  WriteInt32(pixel_ref, 16, width);
  WriteInt32(pixel_ref, 20, height);
  WritePointer(pixel_ref, 24, pixels.data());
  WriteUint64(pixel_ref, 32, row_bytes);

  uint32_t annotation_length = 0;
  char* annotation = g_perform_ocr(bitmap, &annotation_length);
  if (!annotation || annotation_length == 0) {
    if (annotation) {
      g_free_char_array(annotation);
    }
    return 1;
  }
  *output = CopyBytes(reinterpret_cast<uint8_t*>(annotation), annotation_length);
  *output_length = annotation_length;
  g_free_char_array(annotation);
  if (!*output) {
    if (error) {
      *error = CopyCString("Could not allocate ScreenAI OCR output");
    }
    *output_length = 0;
    return 0;
  }
  return 1;
}

extern "C" __declspec(dllexport) int ScreenAiRecognize(
    const wchar_t* component_dir,
    const uint8_t* rgba_pixels,
    int32_t width,
    int32_t height,
    uint8_t** output,
    uint32_t* output_length,
    char** error) {
  // An exception leaving this export would terminate the app. A very large
  // capture can fail to allocate its BGRA copy; report that like any other
  // OCR failure instead.
  try {
    return RecognizeUnchecked(component_dir, rgba_pixels, width, height,
                              output, output_length, error);
  } catch (...) {
    if (output) {
      ScreenAiFreeUnchecked(*output);
      *output = nullptr;
    }
    if (output_length) {
      *output_length = 0;
    }
    if (error && !*error) {
      *error = CopyCString("ScreenAI OCR failed");
    }
    return 0;
  }
}

extern "C" __declspec(dllexport) void ScreenAiFree(void* pointer) {
  ScreenAiFreeUnchecked(pointer);
}
