#ifndef RUNNER_IME_CONTEXT_H_
#define RUNNER_IME_CONTEXT_H_

#include <windows.h>

// Workaround for Flutter Windows IMM32/TSF sessions going stale: key events
// still reach the HWND but WM_IME_* / candidate UI stop (flutter#190042).
// Rotate an app-owned HIMC onto |hwnd|. Skips while composition is active.
void RefreshWindowImeContext(HWND hwnd);

// Destroy the app-owned HIMC created by RefreshWindowImeContext.
void DestroyOwnedImeContext();

#endif  // RUNNER_IME_CONTEXT_H_
