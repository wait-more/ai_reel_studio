#include "ime_context.h"

#include <imm.h>

namespace {

HIMC g_owned_imc = nullptr;

bool HasActiveComposition(HIMC himc) {
  if (himc == nullptr) {
    return false;
  }
  const LONG bytes =
      ::ImmGetCompositionStringW(himc, GCS_COMPSTR, nullptr, 0);
  return bytes > 0;
}

}  // namespace

void DestroyOwnedImeContext() {
  if (g_owned_imc != nullptr) {
    ::ImmDestroyContext(g_owned_imc);
    g_owned_imc = nullptr;
  }
}

void RefreshWindowImeContext(HWND hwnd) {
  if (hwnd == nullptr || !::IsWindow(hwnd)) {
    return;
  }

  HIMC current = ::ImmGetContext(hwnd);
  if (current != nullptr && HasActiveComposition(current)) {
    ::ImmReleaseContext(hwnd, current);
    return;
  }

  BOOL open = FALSE;
  DWORD conversion = 0;
  DWORD sentence = 0;
  if (current != nullptr) {
    open = ::ImmGetOpenStatus(current);
    ::ImmGetConversionStatus(current, &conversion, &sentence);
    ::ImmNotifyIME(current, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
    ::ImmNotifyIME(current, NI_CLOSECANDIDATE, 0, 0);
    ::ImmReleaseContext(hwnd, current);
  }

  HIMC fresh = ::ImmCreateContext();
  if (fresh == nullptr) {
    ::ImmAssociateContextEx(hwnd, nullptr, IACE_DEFAULT);
    return;
  }

  ::ImmSetOpenStatus(fresh, open);
  ::ImmSetConversionStatus(fresh, conversion, sentence);

  HIMC previous = ::ImmAssociateContext(hwnd, fresh);
  if (g_owned_imc != nullptr && previous == g_owned_imc) {
    ::ImmDestroyContext(g_owned_imc);
  }
  // Never ImmDestroyContext a system-default HIMC returned as |previous|.
  g_owned_imc = fresh;
}
