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
@class NSSearchField;
@class NSSegmentedControl;
@class NSTextField;
@class WSColumnView;
@class WSDirectoryWatcher;
@class WSFileOperations;
@class WSIconView;
@class WSListView;
@class WSProgressWindow;
@class WSTrash;
@class WSHairlineView;
@class NSUndoManager;
@class WSHistory;
@class WSItemModel;

@interface WSFileWindowController : NSWindowController
    <NSWindowDelegate, NSToolbarDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
     NSSplitViewDelegate>
{
	NSString *_directory;			/* COPIED: the folder the model holds */
	WSDirectoryWatcher *_watcher;		/* RETAINED: this folder's changes, as the kernel reports them */
	WSItemModel *_model;			/* RETAINED */
	WSHistory *_history;			/* RETAINED */
	NSArray *_placeSections;		/* RETAINED: WSPlaceSection */

	NSPathControl *_pathBar;		/* RETAINED by the content view */
	/* **THE TRASH HAS NO PATH BAR AT ALL**, decided once when the window is built: a strip whose only content would be
	 * a breadcrumb ending in `.Trash` is a strip that says something untrue about the place. */
	BOOL _isTrashDirectory;
	NSArray *_stripConstraints;		/* RETAINED: the strips' layout, taken down when the window enters or leaves the trash */
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
	/* **THE RULE ABOVE THE STATUS BAR**, because that strip is a bare label and has no border of its own: the pane
	 * above it would otherwise meet the window's face with no line, the one edge in this window left unmarked. */
	WSHairlineView *_statusRule;		/* RETAINED by the content view */
	NSToolbar *_toolbar;			/* RETAINED by the window */
	NSSegmentedControl *_viewSwitcher;	/* RETAINED by its toolbar item */
	/* **AND THE SEARCH FIELD BESIDE IT, RETAINED BY ITS OWN TOOLBAR ITEM.** It holds the query while the window lives;
	 * the FILTER is the model's (`-setNameFilter:`), because the content view and both bars read the model. */
	NSSearchField *_searchField;

	BOOL _syncingSidebar;
}

- (instancetype)initWithDirectory:(NSString *)directory;

- (NSString *)directory;
- (NSInteger)itemCount;

/* **PRINTING IS THE FILE MANAGER'S, AND IT IS A LISTING.** `-printablePaths` is the selection when there is one and the
 * whole folder otherwise; `-printSelection:` hands those paths to `-application:printFiles:`, which is the launch's own
 * door — so the menu row is the FIRST REAL CALLER of it rather than a second printing path. */
- (NSArray *)printablePaths;
- (void)printSelection:(nullable id)sender;

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

/* **THE SHARED COMMANDS A CONTEXT MENU ASKS OF WHICHEVER VIEW IS SHOWING** — Cut, Copy, Paste, Rename, New Folder
 * with Selection and Select All, each acting on `-selectedItems` through this window's own operation manager. The
 * views that implement their own (the desktop and the icon view) answer first, being the first responder; List and
 * Column mode reach these. */
- (void)cut:(nullable id)sender;
- (void)copy:(nullable id)sender;
- (void)paste:(nullable id)sender;
- (void)rename:(nullable id)sender;
- (void)newFolderWithSelection:(nullable id)sender;
- (void)selectAll:(nullable id)sender;

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
/* The window's search field, for a test that types into it. Nil before the toolbar is built. */
- (nullable NSSearchField *)cg_searchField;

/* **WHETHER THIS WINDOW IS SHOWING THE TRASH**, which is what puts "Put Back" in its context menus and keeps "Move to
 * Trash" out of them: an item in the bin has a way back, not a way further in. The context menu asks this of whatever
 * owns the selection, so it is a command's fact rather than a flag passed through four views. */
- (BOOL)isTrashDirectory;

/* **THE OPERATIONS THIS WINDOW COMMANDS WITH**, and a door to hand them in: a probe gives the window a trash of its own
 * rather than emptying the account's, and a drop or a put-back is otherwise the real file system's. */
- (nullable WSFileOperations *)fileOperations;
- (void)setFileOperations:(nullable WSFileOperations *)operations;
/* **THE WINDOW'S EAR ON THE FILESYSTEM**, so a probe can turn the main thread's half of it without a run loop: the
 * stream still does its own work on its own thread, and `-cg_drain` is the door the timer uses. */
- (nullable WSDirectoryWatcher *)cg_watcher;
/* The plate a file operation puts up while it runs, so a probe can see that the operation ENDED: the window is closed by
 * `-finishOperation`, and a command that ran an operation without that ending left it on the glass. */
- (nullable WSProgressWindow *)cg_progressWindow;

/* **THE TOOLBAR'S WORDS, AS ONE APPLICATION-WIDE PREFERENCE** — the same arrangement Forge's project window has, because
 * it is the same question. `-cg_applyToolbarLabels` puts the remembered answer on this window's band; the two class
 * doors read and write it; and `+cg_showToolbarLabelsStateOn:` is the tick the View menu asks for on its way to opening. */
+ (BOOL)cg_toolbarLabelsVisible;

/* **THE VIEW A NEW WINDOW OPENS IN** — 0 Icon, 1 List, 2 Column — kept in the standard defaults under
 * `WSDefaultViewMode`. The Preferences window writes it; a file window reads it once, when it is made. */
/* **THE PLACES PANE'S WIDTH**, kept in the standard defaults under `WSSidebarWidth`: what a window opens at, and what a
 * divider drag writes. A width outside the useful range is refused rather than stored. */
+ (CGFloat)cg_sidebarWidth;
+ (void)cg_setSidebarWidth:(CGFloat)width;

+ (NSInteger)cg_defaultViewMode;
+ (void)cg_setDefaultViewMode:(NSInteger)mode;
+ (void)cg_setToolbarLabelsVisible:(BOOL)visible;
- (void)cg_applyToolbarLabels;
+ (void)cg_showToolbarLabelsStateOn:(nullable NSMenuItem *)item;
- (nullable NSSplitView *)cg_splitView;

/* **WHERE A COPY OR AN ARCHIVE IS MADE**: the folder that holds the selection, which is the only thing either command is
 * about. Exposed because a probe checks the rule rather than the pixels. */
- (nullable NSString *)cg_destinationBesideSelection;

/* **EXTRACT ARCHIVE, AS A COMMAND AND AS A QUESTION.** The context menu asks `-cg_selectionCanBeExtracted` before it draws
 * the row — the same arrangement the trash's Put Back uses — and `-extractArchive:` unpacks every selected `.zip` beside
 * itself into a folder named for it. A double click on an archive takes the same command. */
- (BOOL)cg_selectionCanBeExtracted;
- (void)extractArchive:(nullable id)sender;

@end

#endif /* WORKSPACE_WSFILEWINDOWCONTROLLER_H */
