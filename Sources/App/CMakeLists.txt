# Adapted from third_party/cef/*/tests/cefsimple/CMakeLists.txt, replacing
# cefsimple's C++ sources with our Swift/AppKit UI + Obj-C++ bridge, and
# generalized to the CEF_HELPER_APP_SUFFIXES list CEF itself defines (five
# helpers in this CEF version -- see docs/ai-tasks/m0-spike-notes.md).

set(BROWSER_BRIDGE_SRCS
  ../Bridge/BRWApplication.h
  ../Bridge/BRWApplication.mm
  ../Bridge/BRWMessagePump.h
  ../Bridge/BRWMessagePump.mm
  ../Bridge/BRWCefApp.h
  ../Bridge/BRWCefApp.mm
  ../Bridge/BRWClientHandler.h
  ../Bridge/BRWClientHandler.mm
  ../Bridge/BRWEngine.h
  ../Bridge/BRWEngine.mm
  ../Bridge/BRWEngineInternal.h
  ../Bridge/BRWBrowser.h
  ../Bridge/BRWBrowser.mm
  ../Bridge/BRWPageMessageRouter.h
  ../Bridge/BRWPageMessageRouter.mm
  ../Bridge/BRWContentBlocker.h
  ../Bridge/BRWContentBlocker.mm
  ../Bridge/BRWContentBlockerInternal.h
  ../Bridge/BRWThreatList.h
  ../Bridge/BRWThreatList.mm
  ../Bridge/BRWThreatListInternal.h
  )
source_group(Bridge FILES ${BROWSER_BRIDGE_SRCS})

set(BROWSER_SWIFT_SRCS
  main.swift
  AppDelegate.swift
  BrowserWindow.swift
  FindBarController.swift
  BrowserWindowController.swift
  ColorSwatchPicker.swift
  CommandLineArgs.swift
  AppPreferencesStore.swift
  GeneralPaneController.swift
  GlassBackgroundView.swift
  MainMenuBuilder.swift
  NewProfilePrompt.swift
  OmniboxField.swift
  NSColor+Hex.swift
  OmniboxDisplayPreference.swift
  PageZoom.swift
  Profile.swift
  ProfileDotView.swift
  ProfileManager.swift
  Tab.swift
  TabLifecycleCenter.swift
  TabButtonView.swift
  TabDragDiagnostics.swift
  TabStripView.swift
  TabGroup.swift
  TabGroupHeaderView.swift
  TabGroupPrompt.swift
  WindowManager.swift
  SessionStore.swift
  ShortcutsHelp.swift
  ShortcutsOverlayController.swift
  ShortcutsOverlayPanelFactory.swift
  TabCyclingController.swift
  FaviconLoader.swift
  PageMessageDispatcher.swift
  Engine/BrowserEngine.swift
  Engine/CEFEngineAdapter.swift
  Engine/WebKitEngineAdapter.swift
  Routing/RoutingRulesStore.swift
  Routing/RoutingCoordinator.swift
  Routing/SourceAppResolver.swift
  Routing/URLEventHandler.swift
  Routing/SettingsWindowController.swift
  Routing/RoutingRulesPaneController.swift
  Routing/RoutingRuleEditor.swift
  Routing/RunningApplicationPicker.swift
  Routing/LinkHandlingPreferences.swift
  Routing/URLUnshortener.swift
  ProfilesPaneController.swift
  ProfileSwitcher/ProfileSwitcherListView.swift
  ProfileSwitcher/ProfileSwitcherController.swift
  Furniture/ProfileDataStores.swift
  Furniture/OmniboxAutocompleteController.swift
  Furniture/HistoryWindowController.swift
  Furniture/BookmarksWindowController.swift
  Furniture/AddBookmarkPromptController.swift
  Furniture/DownloadCoordinator.swift
  Furniture/DownloadsWindowController.swift
  Permissions/PermissionStore.swift
  Permissions/PermissionPromptController.swift
  Passwords/PasswordDetectionScript.swift
  Passwords/PasswordAutofillPreference.swift
  Passwords/AutofillScript.swift
  Passwords/PasswordStore.swift
  Passwords/PasswordNeverStore.swift
  Passwords/SavePasswordPromptController.swift
  Passwords/PasswordManagerCoordinator.swift
  Passwords/PasswordsPaneController.swift
  Autofill/PaymentAddressDetectionScript.swift
  Autofill/AutofillFillScript.swift
  Autofill/AddressStoreManager.swift
  Autofill/SaveAutofillPromptController.swift
  Autofill/PaymentAddressAutofillCoordinator.swift
  Autofill/CardsPaneController.swift
  Autofill/AddressFormSheetController.swift
  Autofill/AddressesPaneController.swift
  Autofill/AutofillPaneController.swift
  Autofill/ContactsAutofillSource.swift
  Reader/ReaderScripts.swift
  Reader/ReaderPreferences.swift
  Reader/ReaderTemplate.swift
  Reader/ReaderModeController.swift
  Blocking/BlockingSettingsStore.swift
  Blocking/ContentBlockerCoordinator.swift
  Blocking/ThreatWarningSettingsStore.swift
  Blocking/ThreatListCoordinator.swift
  Blocking/PrivacyPaneController.swift
  Blocking/ContentBlockerToolbarController.swift
  StartPage/StartPageSettings.swift
  StartPage/StartPageSections.swift
  StartPage/StartPageRenderer.swift
  StartPage/FavoritesFolder.swift
  Omnibox/AnchoredPanelTracker.swift
  Omnibox/OmniboxStartPanelView.swift
  Omnibox/OmniboxStartPanelController.swift
  StartPage/StartPageSettingsPaneController.swift
  StartPage/StartPageSettingsCoordinator.swift
  Import/BookmarkImportCoordinator.swift
  Import/SafariImportScanner.swift
  Import/SafariImportWindowController.swift
  Import/PasswordImportCoordinator.swift
  TabOverview/TabThumbnailCache.swift
  TabOverview/TabOverviewCellView.swift
  TabOverview/TabOverviewView.swift
  TabOverview/TabOverviewController.swift
  DevTools/ResponsiveDesignMode.swift
  VisualLookUp/VisualLookUpController.swift
  VisualLookUp/VisualLookUpPanelController.swift
  ImageCopy/ImageCopyController.swift
  ImageCopy/ImageDownloadController.swift
  PictureInPicture/PictureInPictureScript.swift
  Notifications/NotificationOverrideScript.swift
  Notifications/WebPushCoordinator.swift
  Audio/AudioStateScript.swift
  Audio/TabAudioCoordinator.swift
  CLI/CLIServer.swift
  )
source_group(App FILES ${BROWSER_SWIFT_SRCS})

# RoutingCore's Rule model + matcher (../../RoutingCore/Sources/RoutingCore)
# are pure Swift/Foundation with no AppKit dependency, so they're also
# packaged standalone as RoutingCore/ at the repo root for a fast, isolated
# `swift test` (see docs/ai-tasks/m2-routing-notes.md). Rather than linking
# that package from this Xcode-generator CMake target (SwiftPM/CMake-Xcode
# interop is its own can of worms), these same source files are just compiled
# directly into the Browser executable here -- one copy of the logic, two ways
# to build it.
set(BROWSER_ROUTING_CORE_SRCS
  ${CMAKE_SOURCE_DIR}/RoutingCore/Sources/RoutingCore/RoutingRule.swift
  ${CMAKE_SOURCE_DIR}/RoutingCore/Sources/RoutingCore/RuleMatcher.swift
  ${CMAKE_SOURCE_DIR}/RoutingCore/Sources/RoutingCore/TrackingParamList.swift
  ${CMAKE_SOURCE_DIR}/RoutingCore/Sources/RoutingCore/TrackingParamStripper.swift
  )
source_group(RoutingCore FILES ${BROWSER_ROUTING_CORE_SRCS})

# BrowserCore's SQLite-backed history/bookmarks/downloads stores
# (../../Packages/BrowserCore/Sources/BrowserCore) are pure Swift/Foundation
# (plus the SDK's built-in SQLite3 module) with no AppKit dependency, so
# they're also packaged standalone as Packages/BrowserCore/ at the repo root
# for a fast, isolated `swift test` (see docs/ai-tasks/m3-furniture-notes.md).
# Same reasoning as BROWSER_ROUTING_CORE_SRCS just above: rather than linking
# that package from this Xcode-generator CMake target, these same source
# files are compiled directly into the Browser executable here too -- one
# copy of the logic, two ways to build it.
set(BROWSER_BROWSER_CORE_SRCS
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/Database.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/ProfilesRootResolver.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/Migrations.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/HistoryStore.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/BookmarkStore.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/DownloadStore.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/NetscapeBookmarkParser.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/SafariBookmarksPlistParser.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/SafariHistoryReader.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/SafariProfileDiscovery.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/PasswordCSVParser.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/BookmarkImporter.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/SQLite/SQLiteError.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/SQLite/Statement.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCore/Sources/BrowserCore/SQLite/SQLiteConnection.swift
  )
source_group(BrowserCore FILES ${BROWSER_BROWSER_CORE_SRCS})

# BlockListCore's domain trie/parser/settings model
# (../../Packages/BlockListCore/Sources/BlockListCore) are pure Swift/
# Foundation with no AppKit dependency, so they're also packaged standalone
# as Packages/BlockListCore/ at the repo root for a fast, isolated
# `swift test` (see Packages/BlockListCore/README.md). Same reasoning as
# BROWSER_ROUTING_CORE_SRCS/BROWSER_BROWSER_CORE_SRCS above: rather than
# linking that package from this Xcode-generator CMake target, these same
# source files are compiled directly into the Browser executable here too --
# one copy of the logic, two ways to build it.
set(BROWSER_BLOCKLIST_CORE_SRCS
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/DomainTrie.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/ListParser.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/BlockList.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/BlockingSettings.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/StarterList.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/RemoteListSource.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/ThreatWarningSettings.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/StarterThreatList.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/ThreatWarningLink.swift
  ${CMAKE_SOURCE_DIR}/Packages/BlockListCore/Sources/BlockListCore/ThreatWarningPageRenderer.swift
  )
source_group(BlockListCore FILES ${BROWSER_BLOCKLIST_CORE_SRCS})

# AutofillCore's card/address heuristic classifier + Keychain/JSON stores
# (../../Packages/AutofillCore/Sources/AutofillCore) are pure Swift/
# Foundation/Security with no AppKit dependency, so they're also packaged
# standalone as Packages/AutofillCore/ at the repo root for a fast, isolated
# `swift test` (browser-ojh.2) -- including real Keychain/filesystem
# round-trip tests, not just pure-function ones (see that package's own
# README/doc comments). Same reasoning as BROWSER_ROUTING_CORE_SRCS/
# BROWSER_BROWSER_CORE_SRCS/BROWSER_BLOCKLIST_CORE_SRCS above: rather than
# linking that package from this Xcode-generator CMake target, these same
# source files are compiled directly into the Browser executable here too --
# one copy of the logic, two ways to build it.
set(BROWSER_AUTOFILL_CORE_SRCS
  ${CMAKE_SOURCE_DIR}/Packages/AutofillCore/Sources/AutofillCore/FieldClassifier.swift
  ${CMAKE_SOURCE_DIR}/Packages/AutofillCore/Sources/AutofillCore/CardStore.swift
  ${CMAKE_SOURCE_DIR}/Packages/AutofillCore/Sources/AutofillCore/AddressStore.swift
  )
source_group(AutofillCore FILES ${BROWSER_AUTOFILL_CORE_SRCS})

# WebEngineCore's WKContentRuleList-JSON builder + profile/data-store UUID
# derivation (../../Packages/WebEngineCore/Sources/WebEngineCore) are pure
# Swift/Foundation with no WebKit/AppKit dependency, so they're also
# packaged standalone as Packages/WebEngineCore/ at the repo root for a
# fast, isolated `swift test` (browser-n50) -- see
# docs/ai-tasks/webkit-engine-adapter-notes.md. Same reasoning as
# BROWSER_ROUTING_CORE_SRCS/BROWSER_BROWSER_CORE_SRCS/BROWSER_BLOCKLIST_CORE_SRCS/
# BROWSER_AUTOFILL_CORE_SRCS above: rather than linking that package from
# this Xcode-generator CMake target, these same source files are compiled
# directly into the Browser executable here too -- one copy of the logic,
# two ways to build it.
set(BROWSER_WEBENGINE_CORE_SRCS
  ${CMAKE_SOURCE_DIR}/Packages/WebEngineCore/Sources/WebEngineCore/ContentRuleListBuilder.swift
  ${CMAKE_SOURCE_DIR}/Packages/WebEngineCore/Sources/WebEngineCore/ProfileDataStoreKey.swift
  )
source_group(WebEngineCore FILES ${BROWSER_WEBENGINE_CORE_SRCS})

# BrowserCLIProtocol's socket-path convention + wire message types
# (../../Packages/BrowserCLIProtocol/Sources/BrowserCLIProtocol) are pure
# Swift/Foundation with no AppKit dependency, so they're also packaged
# standalone as Packages/BrowserCLIProtocol/ at the repo root for a fast,
# isolated `swift test`, and shared with the standalone `browser-cli` SwiftPM
# package (a real path dependency there, unlike this CMake target) -- see
# docs/ai-tasks/browser-cli-notes.md (browser-82d). Same reasoning as
# BROWSER_ROUTING_CORE_SRCS/BROWSER_BROWSER_CORE_SRCS/BROWSER_BLOCKLIST_CORE_SRCS/
# BROWSER_AUTOFILL_CORE_SRCS/BROWSER_WEBENGINE_CORE_SRCS above: rather than
# linking that package from this Xcode-generator CMake target, these same
# source files are compiled directly into the Browser executable here too --
# one copy of the logic, two ways to build it (three, counting browser-cli).
set(BROWSER_CLI_PROTOCOL_SRCS
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCLIProtocol/Sources/BrowserCLIProtocol/CLISocketPath.swift
  ${CMAKE_SOURCE_DIR}/Packages/BrowserCLIProtocol/Sources/BrowserCLIProtocol/CLIMessages.swift
  )
source_group(BrowserCLIProtocol FILES ${BROWSER_CLI_PROTOCOL_SRCS})

set(BROWSER_SRCS
  ${BROWSER_BRIDGE_SRCS}
  ${BROWSER_SWIFT_SRCS}
  ${BROWSER_ROUTING_CORE_SRCS}
  ${BROWSER_BLOCKLIST_CORE_SRCS}
  ${BROWSER_BROWSER_CORE_SRCS}
  ${BROWSER_AUTOFILL_CORE_SRCS}
  ${BROWSER_WEBENGINE_CORE_SRCS}
  ${BROWSER_CLI_PROTOCOL_SRCS}
  )

set(BROWSER_HELPER_SRCS
  ../Bridge/process_helper_mac.mm
  ../Bridge/BRWHelperApp.h
  ../Bridge/BRWHelperApp.mm
  )
source_group(Bridge FILES ${BROWSER_HELPER_SRCS})

set(BROWSER_RESOURCES_MAC_SRCS
  mac/Info.plist.in
  )
source_group(mac FILES ${BROWSER_RESOURCES_MAC_SRCS})

# Target executable names.
set(CEF_TARGET "Browser")
set(CEF_HELPER_TARGET "Browser_Helper")
set(CEF_HELPER_OUTPUT_NAME "Browser Helper")

SET_CEF_TARGET_OUT_DIR()

option(OPTION_USE_ARC "Build with ARC (Automatic Reference Counting) on macOS." ON)
if(OPTION_USE_ARC)
  list(APPEND CEF_COMPILER_FLAGS -fobjc-arc)
endif()

# Output path for the main app bundle.
set(CEF_APP "${CEF_TARGET_OUT_DIR}/${CEF_TARGET}.app")

# Variables referenced from mac/Info.plist.in.
set(EXECUTABLE_NAME "${CEF_TARGET}")
set(PRODUCT_NAME "${CEF_TARGET}")

# Main app bundle target -- Obj-C++ bridge + Swift UI in one CMake/Xcode target.
add_executable(${CEF_TARGET} MACOSX_BUNDLE ${BROWSER_RESOURCES_MAC_SRCS} ${BROWSER_SRCS})
SET_EXECUTABLE_TARGET_PROPERTIES(${CEF_TARGET})
add_dependencies(${CEF_TARGET} libcef_dll_wrapper)
# sqlite3 -- BrowserCore's stores link against the system library (via
# Swift's built-in SQLite3 module import, no header search path needed).
# WebKit -- not part of CEF_STANDARD_LIBS (see third_party/cef's own
# cef_variables.cmake), needed only for Engine/WebKitEngineAdapter.swift's
# `import WebKit` (browser-n50); everything else already links AppKit/Cocoa.
target_link_libraries(${CEF_TARGET} libcef_dll_wrapper ${CEF_STANDARD_LIBS} sqlite3 "-framework WebKit")
set_target_properties(${CEF_TARGET} PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/mac/Info.plist.in
  XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/BrowserApp-Bridging-Header.h"
  XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
  )

# Copy the CEF framework into the Frameworks directory and create the necessary symlinks.
COPY_MAC_FRAMEWORK("${CEF_TARGET}" "${CEF_BINARY_DIR}" "${CEF_APP}")

# App icon: Info.plist.in's CFBundleIconFile references "AppIcon" (no
# extension, per Apple convention), so the .icns just needs to land in
# Contents/Resources under that name. Not routed through COPY_MAC_RESOURCES --
# that macro's prefix-stripping is tuned for paths under mac/, not an
# arbitrary absolute path outside Sources/App.
add_custom_command(
  TARGET ${CEF_TARGET}
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CEF_APP}/Contents/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy
          "${CMAKE_SOURCE_DIR}/assets/branding/AppIcon.icns"
          "${CEF_APP}/Contents/Resources/AppIcon.icns"
  VERBATIM
  )

# Reader mode's vendored Readability.js/Readability-readerable.js
# (browser-5kq.1) -- loaded at runtime via Bundle.main.url(forResource:
# withExtension:subdirectory:) (see ReaderScripts.swift), same
# not-routed-through-COPY_MAC_RESOURCES reasoning as the app icon above.
add_custom_command(
  TARGET ${CEF_TARGET}
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CEF_APP}/Contents/Resources/Reader"
  COMMAND ${CMAKE_COMMAND} -E copy
          "${CMAKE_SOURCE_DIR}/Sources/App/Reader/Readability.js"
          "${CEF_APP}/Contents/Resources/Reader/Readability.js"
  COMMAND ${CMAKE_COMMAND} -E copy
          "${CMAKE_SOURCE_DIR}/Sources/App/Reader/Readability-readerable.js"
          "${CEF_APP}/Contents/Resources/Reader/Readability-readerable.js"
  VERBATIM
  )

# Crash reporting (browser-6iv): CEF reads "crash_reporter.cfg" from exactly
# this path -- the top-level app bundle's Contents/Resources -- and enables
# Crashpad only if it's there (include/cef_crash_util.h). Copied here rather
# than from scripts/build.sh so every route that produces a bundle gets it,
# scripts/release.sh's separate build-release/ tree included, and so it's in
# place before either script's signing pass seals Contents/Resources.
add_custom_command(
  TARGET ${CEF_TARGET}
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy
          "${CMAKE_CURRENT_SOURCE_DIR}/mac/crash_reporter.cfg"
          "${CEF_APP}/Contents/Resources/crash_reporter.cfg"
  VERBATIM
  )

# Map each helper's CMake target-name suffix to its entitlements file. Only
# the GPU and Renderer helpers need JIT / unsigned-executable-memory; every
# helper needs disable-library-validation because every helper dynamically
# loads the (ad-hoc-signed, for local dev) CEF framework.
function(browser_entitlements_for_suffix _target_suffix _out_var)
  if(_target_suffix STREQUAL "_gpu")
    set(${_out_var} "${CMAKE_SOURCE_DIR}/entitlements/helper-gpu.entitlements" PARENT_SCOPE)
  elseif(_target_suffix STREQUAL "_renderer")
    set(${_out_var} "${CMAKE_SOURCE_DIR}/entitlements/helper-renderer.entitlements" PARENT_SCOPE)
  elseif(_target_suffix STREQUAL "_plugin")
    set(${_out_var} "${CMAKE_SOURCE_DIR}/entitlements/helper-plugin.entitlements" PARENT_SCOPE)
  elseif(_target_suffix STREQUAL "_alerts")
    set(${_out_var} "${CMAKE_SOURCE_DIR}/entitlements/helper-alerts.entitlements" PARENT_SCOPE)
  else()
    set(${_out_var} "${CMAKE_SOURCE_DIR}/entitlements/helper.entitlements" PARENT_SCOPE)
  endif()
endfunction()

# Written for scripts/sign.sh to consume: "<kind>|<relative path>|<entitlements
# path>" lines, one per helper, plus the main app's own entitlements last.
# CEF_TARGET_OUT_DIR embeds an unevaluated $<CONFIGURATION> generator
# expression under the Xcode generator, so this has to go through
# file(GENERATE) rather than file(WRITE) -- the latter runs at configure time
# and would write the literal string "$<CONFIGURATION>" into the path.
set(_manifest_content "")

foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
  # Convert to a list and extract the suffix values.
  string(REPLACE ":" ";" _suffix_list ${_suffix_list})
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)

  set(_helper_target "${CEF_HELPER_TARGET}${_target_suffix}")
  set(_helper_output_name "${CEF_HELPER_OUTPUT_NAME}${_name_suffix}")

  # Create Helper-specific variants of the helper-Info.plist file.
  set(_helper_info_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/mac/helper-Info.plist.in" _plist_contents)
  string(REPLACE "\${EXECUTABLE_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${PRODUCT_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
  string(REPLACE "\${BUNDLE_ID_SUFFIX}" "${_plist_suffix}" _plist_contents ${_plist_contents})
  file(WRITE ${_helper_info_plist} ${_plist_contents})

  # Create Helper executable target.
  add_executable(${_helper_target} MACOSX_BUNDLE ${BROWSER_HELPER_SRCS})
  SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
  add_dependencies(${_helper_target} libcef_dll_wrapper)
  target_link_libraries(${_helper_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_helper_target} PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${_helper_info_plist}
    OUTPUT_NAME ${_helper_output_name}
    )

  add_dependencies(${CEF_TARGET} "${_helper_target}")

  # Copy the Helper app bundle into the Frameworks directory.
  add_custom_command(
    TARGET ${CEF_TARGET}
    POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CEF_TARGET_OUT_DIR}/${_helper_output_name}.app"
            "${CEF_APP}/Contents/Frameworks/${_helper_output_name}.app"
    VERBATIM
    )

  browser_entitlements_for_suffix("${_target_suffix}" _helper_entitlements)
  string(APPEND _manifest_content "helper|Contents/Frameworks/${_helper_output_name}.app|${_helper_entitlements}\n")
endforeach()

string(APPEND _manifest_content "app|.|${CMAKE_SOURCE_DIR}/entitlements/browser.entitlements\n")
file(GENERATE OUTPUT "${CEF_TARGET_OUT_DIR}/.codesign-manifest" CONTENT "${_manifest_content}")

# Manually process and copy over resource files (handles nested resource
# directories, which the Xcode generator's RESOURCE property does not).
set(PREFIXES "mac/")
COPY_MAC_RESOURCES("${BROWSER_RESOURCES_MAC_SRCS}" "${PREFIXES}" "${CEF_TARGET}" "${CMAKE_CURRENT_SOURCE_DIR}" "${CEF_APP}")
