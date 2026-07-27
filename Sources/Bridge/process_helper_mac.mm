// Entry point for the four (well, five -- see m0-spike-notes.md) Helper.app
// bundles. Chrome-bootstrap CEF requires renderer/GPU/etc. subprocesses to
// run from separate signed helper bundles rather than re-executing the main
// app; this is that separate binary. Copied in spirit from CEF's own
// tests/cefsimple/process_helper_mac.cc sample.
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

int main(int argc, char *argv[]) {
#if defined(CEF_USE_SANDBOX)
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
#endif

  // Load the CEF framework library at runtime instead of linking directly,
  // as required by the macOS sandbox implementation.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
