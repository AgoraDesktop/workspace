# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later

# Workspace's own suite.
#
# W0 IS MEASURED AGAINST AGORA'S OWN WINDOW SERVER, because a desktop window is only a desktop window if the
# COMPOSITOR put it below everything. The suite runs the server headless, runs the BUNDLE's executable (not the
# bare binary — the bundle path is part of what W0 proves), places a NORMAL window over the desktop with the
# server's own test client, and reads the server's screenshot.

find_program(PYTHON3 python3 REQUIRED)

# THE OFFSCREEN SUITES need no compositor. Most need Foundation alone; the file window needs the AppKit too, and the
# icon service because its sidebar and grid draw real icons.
find_package(Foundation CONFIG REQUIRED)
find_package(ZLIB REQUIRED)
find_package(libobjc CONFIG REQUIRED)

add_executable(desktop_layout desktop_layout.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLayout.m")
target_include_directories(desktop_layout PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(desktop_layout PRIVATE Foundation::Foundation objc)
add_test(NAME workspace-desktop-layout COMMAND desktop_layout)
set_tests_properties(workspace-desktop-layout PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

add_executable(metadata_store metadata_store.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMetadataStore.m")
target_include_directories(metadata_store PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(metadata_store PRIVATE Foundation::Foundation objc)
add_test(NAME workspace-metadata-store COMMAND metadata_store)
set_tests_properties(workspace-metadata-store PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

# **THE MENU BAR'S CONTENTS, WHICH NEED THE APPKIT BUT NOT A COMPOSITOR.** `-setMainMenu:` builds the bar's
# WINDOW from the region the compositor sends, so with no compositor there is no window to look at — but the MENU
# is built first and entirely, and every decision this component made is in it: which menus there are, what the
# application menu offers, where each row is sent, and what `-update`'s enabling walk makes of the result. The ink
# in the strip is the desktop suite's to measure; this is the menu's.
add_executable(main_menu main_menu.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMainMenu.m")
target_include_directories(main_menu PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(main_menu PRIVATE AgoraApp::App Foundation::Foundation objc)
add_test(NAME workspace-main-menu COMMAND main_menu)
# The AppKit's own dependencies arrive through the prefix, and DT_RUNPATH is not inherited by a dependency — the
# same reason libagora-app's tests set this, and it is the imported target's directory rather than a written path.
set_tests_properties(workspace-main-menu PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>")

# **THE MENU BAR'S CLOCK, WITHOUT A COMPOSITOR.** A status item is placed by the server, so the ITEM is the desktop
# suite's to measure; what is measurable here is everything the application owns — the width arithmetic, the ink inside
# the item's padding, the locale's answer, and the fact that a process with no bar has no item but still has a clock.
add_executable(menu_bar_clock menu_bar_clock.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMenuBarClock.m")
target_include_directories(menu_bar_clock PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(menu_bar_clock PRIVATE AgoraApp::App Foundation::Foundation objc)
add_test(NAME workspace-menu-bar-clock COMMAND menu_bar_clock)
set_tests_properties(workspace-menu-bar-clock PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>")


# **THE GO MENU, LAID OUT AND DRAWN.** It is the one menu with a key equivalent that is not a character (⌘↑, the
# UP ARROW function key in the Private Use Area), and drawing a dropdown MEASURES that string and inks its glyph —
# so this is where a font with nothing for that code point shows up. Opening the menu crashed; this is that,
# offscreen.
add_executable(go_menu go_menu.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMainMenu.m")
target_include_directories(go_menu PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(go_menu PRIVATE AgoraApp::App Foundation::Foundation objc)
add_test(NAME workspace-go-menu COMMAND go_menu)
set_tests_properties(workspace-go-menu PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>")

# The sibling's built outputs. Named and cached BEFORE use, so a fresh configure does not expand them to
# nothing — the trap libagora-app's own tests record.
set(AGORA_WINDOW_SERVER_BINARY
    "${CMAKE_CURRENT_SOURCE_DIR}/../../window-server/build/window-server"
    CACHE FILEPATH "window-server's built binary, for the desktop suite")
set(AGORA_WINDOW_SERVER_TEST_CLIENT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../window-server/build/tests/window-server-test-client"
    CACHE FILEPATH "window-server's test client, which draws a NORMAL window over the desktop")

add_test(NAME workspace-desktop
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run-desktop.sh"
            "${WORKSPACE_BUNDLE_EXECUTABLE}"
            "${AGORA_WINDOW_SERVER_BINARY}"
            "${AGORA_WINDOW_SERVER_TEST_CLIENT}"
            "${PYTHON3}"
            "${CMAKE_CURRENT_SOURCE_DIR}/check.py")

set_tests_properties(workspace-desktop PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:AgoraApp::App>")

# **AND AN ORDINARY LAUNCH STAYS, WHICH IS THE ONE THING A DESKTOP MUST DO.** The three-second deadline used to be
# installed for every launch, so a session whose launcher treated Workspace as its foreground process lost the desktop
# about three seconds in. This measures the process, not a picture: with no arguments it is still running after five
# seconds, and `--seconds 0.2` and `--seconds 0` still leave on their own — the flag is what bounds a run.
add_test(NAME workspace-default-run
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run-default-run.sh"
            "${WORKSPACE_BUNDLE_EXECUTABLE}"
            "${AGORA_WINDOW_SERVER_BINARY}")

set_tests_properties(workspace-default-run PROPERTIES
    SKIP_RETURN_CODE 77
    ENVIRONMENT "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:AgoraApp::App>")

# **THE HISTORY, WITHOUT A WINDOW.** Back/Forward is a stack and a cursor; the view only asks whether the arrows
# are possible. Foundation-only, so it runs anywhere.
add_executable(history history.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSHistory.m")
target_include_directories(history PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(history PRIVATE Foundation::Foundation objc)
add_test(NAME workspace-history COMMAND history)
set_tests_properties(workspace-history PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

# **THE W2 SHELL, OFFSCREEN.** One folder, one model: the title, path bar, status bar and icon view are four
# renderings of it, and a second controller is a second model and history. It needs the AppKit but no compositor;
# the icon service is the real one, because the sidebar and the grid draw real icons.
find_package(AgoraIconServices CONFIG REQUIRED)
find_package(AgoraLaunchServices CONFIG REQUIRED)

add_executable(file_window file_window.m
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSConflictSheet.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSFileOperations.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSProgressWindow.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSFileWindowController.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSColumnView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLabel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSHistory.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLayout.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemIcons.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemKind.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemModel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemSort.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSListView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSPlaces.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSTrash.m")
target_include_directories(file_window PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(file_window PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    AgoraLaunchServices::LaunchServices
    Foundation::Foundation
    ZLIB::ZLIB
    objc)
add_test(NAME workspace-file-window COMMAND file_window)
set_tests_properties(workspace-file-window PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>:$<TARGET_FILE_DIR:AgoraIconServices::IconServices>:$<TARGET_FILE_DIR:AgoraLaunchServices::LaunchServices>")

# **W3'S ICON VIEW.** The grid order, the keyboard and type-select, the inline rename, the drag pasteboard and the
# drop policies — with a second root on /dev/shm so "across a volume" is measured rather than asserted.
add_executable(icon_view icon_view.m
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLabel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLayout.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemIcons.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemModel.m")
target_include_directories(icon_view PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(icon_view PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    Foundation::Foundation
    objc)
add_test(NAME workspace-icon-view COMMAND icon_view)
set_tests_properties(workspace-icon-view PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>:$<TARGET_FILE_DIR:AgoraIconServices::IconServices>")

# **W4'S LIST VIEW.** Columns, directories-first natural order, the expansion across a reload and a rename through
# the field editor, and the row's icon. Needs the AppKit, Icon Services (the row icon) and Launch Services (the Kind
# column) but no compositor.
add_executable(list_view list_view.m
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSListView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemIcons.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemKind.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemModel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemSort.m")
target_include_directories(list_view PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(list_view PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    AgoraLaunchServices::LaunchServices
    Foundation::Foundation
    objc)
add_test(NAME workspace-list-view COMMAND list_view)
set_tests_properties(workspace-list-view PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>:$<TARGET_FILE_DIR:AgoraIconServices::IconServices>:$<TARGET_FILE_DIR:AgoraLaunchServices::LaunchServices>")

# **W5'S COLUMN VIEW.** The browser's columns, the selection that opens the next one, and the preview. Needs the
# AppKit, Icon Services and Launch Services; no compositor.
add_executable(column_view column_view.m
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSColumnView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemIcons.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemKind.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemModel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemSort.m")
target_include_directories(column_view PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(column_view PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    AgoraLaunchServices::LaunchServices
    Foundation::Foundation
    objc)
add_test(NAME workspace-column-view COMMAND column_view)
set_tests_properties(workspace-column-view PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>:$<TARGET_FILE_DIR:AgoraIconServices::IconServices>:$<TARGET_FILE_DIR:AgoraLaunchServices::LaunchServices>")

# **THE TRASH, WITHOUT A DISPLAY.** Recycle, unique names, Put Back, a directory, and an empty — over an explicit
# root that keeps the probe out of the real home directory.
add_executable(trash trash.m "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSTrash.m")
target_include_directories(trash PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(trash PRIVATE Foundation::Foundation objc)
add_test(NAME workspace-trash COMMAND trash)
set_tests_properties(workspace-trash PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

# **W6'S FILE OPERATIONS.** New Folder, Duplicate, Rename, Move/Copy (including across /dev/shm), Trash, Put Back,
# Empty and Compress, each followed by its Undo. Offscreen; zlib writes the ZIP.
add_executable(file_ops file_ops.m
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSFileOperations.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSTrash.m")
target_include_directories(file_ops PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(file_ops PRIVATE Foundation::Foundation ZLIB::ZLIB objc)
add_test(NAME workspace-file-ops COMMAND file_ops)
set_tests_properties(workspace-file-ops PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>")

# **PRINTING: THE LISTING A FILE MANAGER CAN PRINT.** The printable view's rows and height, a three-row page and a
# hundred-row three-page listing, the ink on page one, the service's preview/save/cancel replies, the application's
# delegate door, and the window's verb measured THROUGH NSApplication with a recording delegate — so no job touches a
# printer and the probe runs anywhere. The sources are the view, the service and the two model files the view asks for
# a kind and a size.
add_executable(printing printing.m
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSPrintView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSPrintService.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSApplication.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSFileWindowController.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSAboutPanel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSDesktopWindow.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSDesktopView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSColumnView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSConflictSheet.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSFileOperations.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSHistory.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLabel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSIconLayout.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemIcons.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemKind.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemModel.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSItemSort.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSListView.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMainMenu.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMetadataStore.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSMenuBarClock.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSPlaces.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSPreferencesWindow.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSProgressWindow.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/WSTrash.m")
target_include_directories(printing PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../src")
target_link_libraries(printing PRIVATE
    AgoraApp::App
    AgoraIconServices::IconServices
    AgoraLaunchServices::LaunchServices
    Foundation::Foundation
    ZLIB::ZLIB
    objc)
add_test(NAME workspace-printing COMMAND printing)
set_tests_properties(workspace-printing PROPERTIES ENVIRONMENT
    "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Foundation::Foundation>:$<TARGET_FILE_DIR:AgoraApp::App>:$<TARGET_FILE_DIR:AgoraIconServices::IconServices>:$<TARGET_FILE_DIR:AgoraLaunchServices::LaunchServices>")
