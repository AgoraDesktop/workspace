# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later

#===----------------------------------------------------------------------===#
#
# Agora's build for Workspace, the file manager and the desktop.
#
# W0 IS THE SMALLEST HONEST WORKSPACE: it launches, it makes ONE borderless window at the desktop level, and it
# fills it with the Argentum wallpaper. It is an APPLICATION, so it consumes the AppKit as a built package
# (`AgoraApp::App`) and installs no package of its own — an application is not a library. It DOES install its
# BUNDLE, which is the other half of being an application: see the install block at the end of this file.
#
# THE BUNDLE IS PART OF THE DELIVERABLE. A program with an `Info.plist` beside it IS a bundle, and that is what
# the launch path and `libagora-launchservices` read, so the build lays `Workspace.app/Contents/` out rather
# than leaving a bare executable.
#
#===----------------------------------------------------------------------===#

cmake_minimum_required(VERSION 3.24)

project(AgoraWorkspace VERSION 0.1.0 LANGUAGES C OBJC)

include(GNUInstallDirs)

set(CMAKE_POSITION_INDEPENDENT_CODE YES)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# THE APPkit, AS A BUILT PACKAGE. It brings Foundation, Core Graphics, Core Text and the Objective-C runtime
# on its own interface, so nothing else is found here.
find_package(AgoraApp CONFIG REQUIRED)
find_package(AgoraIconServices CONFIG REQUIRED)
find_package(AgoraLaunchServices CONFIG REQUIRED)
find_package(ZLIB REQUIRED)

add_executable(Workspace
    src/main.m
    src/WSAboutPanel.m
    src/WSApplication.m
    src/WSDesktopWindow.m
    src/WSDesktopView.m
    src/WSIconView.m
    src/WSColumnView.m
    src/WSConflictSheet.m
    src/WSFileOperations.m
    src/WSFileWindowController.m
    src/WSHistory.m
    src/WSIconLabel.m
    src/WSIconLayout.m
    src/WSItemIcons.m
    src/WSItemKind.m
    src/WSItemModel.m
    src/WSItemSort.m
    src/WSMainMenu.m
    src/WSMenuBarClock.m
    src/WSListView.m
    src/WSMetadataStore.m
    src/WSPlaces.m
    src/WSTrash.m
    src/WSProgressWindow.m
    src/WSPreferencesWindow.m)

# **THE CHROME'S THEME, AS THE APPKIT'S OWN DEMONSTRATION DOES IT.** The library resolves a theme only when
# `AGORA_CHROME_THEME` names one — the right default for a LIBRARY, which must not go looking for other people's
# art. An APPLICATION is the other case: without a theme its windows draw the chrome's fallback marks, which is
# why Workspace's About window showed flat grey stoplights beside the controls demo's real ones. The directory is
# the sibling's and is git-ignored (it may be absent), and an explicit `AGORA_CHROME_THEME` still wins.
# The path is resolved to a REAL one, so the resolved theme a log prints has no `..` in it.
get_filename_component(_ws_chrome_themes
    "${CMAKE_CURRENT_SOURCE_DIR}/../libagora-app/themes" REALPATH BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(Workspace PRIVATE AGORA_CHROME_DEFAULT_THEME="${_ws_chrome_themes}")

target_include_directories(Workspace PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(Workspace PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    AgoraLaunchServices::LaunchServices
    ZLIB::ZLIB)

# ---------------------------------------------------------------------------
# The bundle: Workspace.app/Contents/{Info.plist, <platform>/<arch>/Workspace}
# ---------------------------------------------------------------------------
# **THE DIRECTORY NAMES ARE libagora-core'S VOCABULARY, NOT CMAKE'S.** The resolver
# (`_CFBundleCopyPlatformDirectoryNames` / `_CFBundleCopyArchitectureDirectoryNames`) spells the platform
# `Linux`, `FreeBSD`, `NetBSD`, `OpenBSD`, `DragonFly` or `MacOS`, and the architecture `amd64`, `arm64`,
# `riscv64`, `i386` or `ppc64`. A build that laid down CMake's `x86_64` — or a directory per uname's
# `Darwin` — would produce a bundle this tree cannot launch, and it would say so only at run time.
#
# THE ARCHITECTURE IS A DIRECTORY, NOT A FILE-NAME SUFFIX, because the kernel reports the executable's
# basename as the process name (`comm`, 15 characters on Linux) and `-[NSProcessInfo processName]` titles
# the application menu: `Workspace-aarch64` would be shown as `Workspace-aarch6`.

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(_bundle_platform "MacOS")
elseif(CMAKE_SYSTEM_NAME MATCHES "^(Linux|FreeBSD|NetBSD|OpenBSD|DragonFly)$")
    set(_bundle_platform "${CMAKE_SYSTEM_NAME}")
else()
    message(FATAL_ERROR
        "Workspace: no bundle platform directory is named for ${CMAKE_SYSTEM_NAME}. Add the name to "
        "_CFBundleCopyPrimaryPlatformDirectoryName() in libagora-core first, so the resolver and the build "
        "cannot disagree.")
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
    set(_bundle_arch "amd64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
    set(_bundle_arch "arm64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^riscv64$")
    set(_bundle_arch "riscv64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(i[3-6]86|x86)$")
    set(_bundle_arch "i386")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ppc64|ppc64le|powerpc64)$")
    set(_bundle_arch "ppc64")
else()
    message(FATAL_ERROR
        "Workspace: no bundle architecture directory is named for ${CMAKE_SYSTEM_PROCESSOR}. Add the name "
        "to _CFBundleCopyArchitectureDirectoryNames() in libagora-core first.")
endif()

set(_bundle "${CMAKE_BINARY_DIR}/Workspace.app")
set(WORKSPACE_BUNDLE_EXECUTABLE
    "${_bundle}/Contents/${_bundle_platform}/${_bundle_arch}/Workspace")

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in" "${_bundle}/Contents/Info.plist" @ONLY)
add_custom_command(TARGET Workspace POST_BUILD
    # A build tree made before the platform axis still carries `Contents/MacOS/Workspace`, which the resolver
    # would find (as the universal slot) and run INSTEAD of this build's executable. Remove it.
    COMMAND "${CMAKE_COMMAND}" -E remove -f "${_bundle}/Contents/MacOS/Workspace"
    COMMAND "${CMAKE_COMMAND}" -E make_directory
            "${_bundle}/Contents/${_bundle_platform}/${_bundle_arch}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:Workspace>"
            "${WORKSPACE_BUNDLE_EXECUTABLE}"
    # **AND THE BUNDLE'S ICON, WHERE `CFBundleIconFile` SAYS IT IS.** `Contents/Resources/Workspace.icns` is Home
    # folder art from the vendored Frost theme, packed at five sizes; Icon Services reads it for the Dock's tile and
    # for anything else that shows the application.
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${_bundle}/Contents/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${CMAKE_CURRENT_SOURCE_DIR}/Resources/Workspace.icns"
            "${_bundle}/Contents/Resources/Workspace.icns"
    VERBATIM)

enable_testing()
add_subdirectory(tests)

# ---------------------------------------------------------------------------
# The install: the same bundle, laid out under the prefix — by CMake, not by a directory copy
# ---------------------------------------------------------------------------
# **A SUCCESSFUL COMPILE IS NOT AN INSTALLABLE APPLICATION, AND `-E copy_directory` IS NOT `install(TARGETS)`.**
# Two things belong to the install and to nothing else.
#
# FIRST, THE LAYOUT: the executable has to land in the bundle's own slot under the prefix, beside the `Info.plist`
# and the `Resources` directory, because what `libagora-core`'s resolver reads is a SHAPE
# (`Contents/<platform>/<arch>/<name>`) and not a bare file. The names above are reused verbatim, so the installed
# bundle cannot disagree with the build-tree one.
#
# SECOND — THE PART A COPY GETS WRONG — THE RUNPATH. CMake REWRITES the executable's dynamic search path at install
# time: the build tree links against build locations, and copying the bundle wholesale carried those into the installed
# tree, where they are stale or absent. `install(TARGETS)` replaces them with `INSTALL_RPATH`, stated here as this
# prefix's own library directory — the same answer the build tree already runs with, because that is where this build's
# AppKit, Foundation and Icon Services come from. A stated install path is not a leaked build path; that is the whole
# difference between the two, and it is why the copy was not equivalent.
#
# **WHAT THIS DOES NOT FIX IS A DEPENDENCY'S DEPENDENCY.** A `DT_RUNPATH` is not consulted for the libraries a
# library needs, and `libagora-base`/`libagora-core` are installed with an empty runpath over their own
# `libagora-dispatch`/`libBlocksRuntime` neighbours — so an installed bundle still wants `LD_LIBRARY_PATH` until
# THOSE install rules carry an `$ORIGIN`. That is their fix to make, and `README.md` records it as the known gap
# rather than letting it read as a broken install here.
#
# THE DESTINATION IS `libexec` AND NOT `bin`: a bundle is not a `$PATH` program. `bin` is for the executable a person
# types. This one is started by `libagora-launchservices` FROM the bundle it reads, so the thing installed is the whole
# `Workspace.app` directory, and the file inside it is nobody's command.
set(_bundle_install "${CMAKE_INSTALL_LIBEXECDIR}/Workspace.app")

set_target_properties(Workspace PROPERTIES
    INSTALL_RPATH "${CMAKE_INSTALL_FULL_LIBDIR}")

install(TARGETS Workspace
    RUNTIME DESTINATION "${_bundle_install}/Contents/${_bundle_platform}/${_bundle_arch}")

# The plist is `configure_file`'s output, so it is installed from the bundle the configure step wrote rather than
# configured a second time — one source, one substitution, and the installed plist cannot drift from the built one.
install(FILES "${_bundle}/Contents/Info.plist"
    DESTINATION "${_bundle_install}/Contents")

# AND THE ICON, WHERE `CFBundleIconFile` SAYS IT IS — the installed tile reads it from the same relative path.
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/Resources/Workspace.icns"
    DESTINATION "${_bundle_install}/Contents/Resources")
