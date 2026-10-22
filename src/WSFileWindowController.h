/*
 * WSFileWindowController.h — the file window's shell.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **W2 IS THE SHELL, NOT THE VIEWS.** One folder, one `WSItemModel`, and the chrome a person navigates with: a
 * toolbar, a sidebar of places, a path bar, a status bar and the three-way view switcher. The Icon mode is W3's
 * `WSIconView`; the List mode is W4's `WSListView`; the Column mode is W5's `WSColumnView`; and the file
 * operations, undo, Trash and progress are W6's `WSFileOperations`/`WSTrash`.
 *
 * **THE WINDOW IS A SHELL OVER THE MODEL.** The title, the status bar, the path bar and the content view are all
 * renderings of the same `WSItemModel`; navigating replaces that model and tells every one of them, rather than
 * each view owning a directory of its own. That is the property W2 exists to prove.
 *
 * **HISTORY IS `WSHistory`'S.** Back and Forward move its cursor; a new navigation pushes and truncates; the
 * window only asks whether the arrows are possible. `tests/history.m` measures the stack, `tests/file_window.m`
 * measures that the window and its status bar are reading the model.
 */
#ifndef WORKSPACE_WSFILEWINDOWCONTROLLER_H
#define WORKSPACE_WSFILEWINDOWCONTROLLER_H

#import <AppKit/NSOutlineView.h>
#import <AppKit/NSSplitView.h>
#import <AppKit/NSToolbar.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSWindowController.h>

@class NSMenuItem;
@class NSPathControl;
@class NSScrollView;
@class NSSegmentedControl;
@class NSTextField;
@class WSColumnView;
@class WSFileOperations;
@class WSIconView;
@class WSListView;
@class WSProgressWindow;
@class WSTrash;
@class NSUndoManager;
@class WSHistory;
@class WSItemModel;

@interface WSFileWindowController : NSWindowController
    <NSWindowDelegate, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
     NSSplitViewDelegate>
{
	NSString *_directory;			/* COPIED: the folder the model holds */
	WSItemModel *_model;			/* RETAINED */
	WSHistory *_history;			/* RETAINED */
	NSArray *_placeSections;		/* RETAINED: WSPlaceSection */

	NSPathControl *_pathBar;		/* RETAINED by the content view */
	NSSplitView *_split;			/* RETAINED by the content view */
	NSOutlineView *_sidebar;		/* RETAINED by its scroll view */
	NSScrollView *_sidebarScroll;		/* RETAINED by the split view */
	WSIconView *_iconView;		/* RETAINED by its scroll view */
	WSListView *_listView;		/* RETAINED by the scroll view when List is chosen */
	WSColumnView *_columnView;		/* RETAINED by the scroll view when Column is chosen */
	NSScrollView *_contentScroll;		/* RETAINED by the split view */
	NSInteger _viewMode;			/* 0 Icon, 1 List, 2 Column */
	NSUndoManager *_undoManager;		/* RETAINED */
	WSFileOperations *_fileOperations;	/* RETAINED */
	WSTrash *_trash;			/* RETAINED */
	WSProgressWindow *_progressWindow;	/* RETAINED, made on demand */
	NSTextField *_status;			/* RETAINED by the content view */
	NSToolbar *_toolbar;			/* RETAINED by the window */
	NSSegmentedControl *_viewSwitcher;	/* RETAINED by its toolbar item */

	BOOL _syncingSidebar;
}

- (instancetype)initWithDirectory:(NSString *)directory;

- (NSString *)directory;
- (NSInteger)itemCount;

- (BOOL)canGoBack;
- (BOOL)canGoForward;
- (void)goBack:(nullable id)sender;
- (void)goForward:(nullable id)sender;

/* Navigate and PUSH, which is what a path-bar click, a sidebar click and a double-click all do. */
- (void)navigateToDirectory:(NSString *)directory;
- (void)goToEnclosingFolder:(nullable id)sender;
- (void)goHome:(nullable id)sender;
- (void)goToDesktop:(nullable id)sender;
- (void)goToApplications:(nullable id)sender;
- (void)goToComputer:(nullable id)sender;

/* THE VIEW SWITCHER'S ACTIONS. Icon and List are implemented; Column answers NO from `-validateMenuItem:` and
 * its segment is disabled. */
- (void)cg_useIconView:(nullable id)sender;
- (void)cg_useListView:(nullable id)sender;
- (void)cg_useColumnView:(nullable id)sender;
- (NSInteger)viewMode;
- (void)setViewMode:(NSInteger)mode;

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;

/* **THE TEST'S SEAMS.** The shell's parts are the point, so a probe names them rather than walking a view tree
 * by class: what the status bar SAYS, which URL the path bar holds, and the icon view the model feeds. */
- (nullable NSOutlineView *)cg_sidebarOutline;
- (nullable NSPathControl *)cg_pathControl;
- (nullable NSTextField *)cg_statusField;
- (nullable WSIconView *)cg_iconView;
- (nullable WSListView *)cg_listView;
- (nullable WSColumnView *)cg_columnView;
- (nullable NSSegmentedControl *)cg_viewSwitcher;
- (nullable NSSplitView *)cg_splitView;

@end

#endif /* WORKSPACE_WSFILEWINDOWCONTROLLER_H */
