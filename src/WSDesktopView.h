/*
 * WSDesktopView.h — the desktop's own view: the wallpaper, and the icons on it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * W1 MAKES THIS A FILE MANAGER SURFACE RATHER THAN WALLPAPER: it draws one icon per item in a directory, lets a
 * person select them, rubber-band a group, drag them to new places and open them. The three pieces it is built
 * from are separate on purpose — `WSItemModel` (what is there), `WSIconLayout` (where icons go) and
 * `WSMetadataStore` (where a person put them) — because the file window's views will be built from the same
 * three.
 */
#ifndef WORKSPACE_WSDESKTOPVIEW_H
#define WORKSPACE_WSDESKTOPVIEW_H

#import <AppKit/NSView.h>

/* **THE PROTOCOLS THIS VIEW ANSWERS FOR A DRAG**, because a class that conforms to one has to have its definition — a
 * forward declaration names it and does not describe it, which the compiler says out loud. */
#import "WSItemDrag.h"

@class NSMutableArray;
@class NSMenu;
@class WSDirectoryWatcher;
@class NSString;
@class NSTextField;
@class WSFileOperations;
@class WSItemModel;
@class WSMetadataStore;
@class WSTrash;


/* **A FOLDER IS THE APPLICATION'S TO OPEN, NOT THIS VIEW'S.** The desktop posts this when a folder is
 * double-clicked; `WSApplication` makes the file window. A view that made windows itself would be a second place
 * that knows what a window is, and the desktop is not a file manager's private background. The userInfo carries
 * the folder's path under `WSDesktopViewPathKey`. */
extern NSString *WSDesktopViewOpenFolderNotification;
extern NSString *WSDesktopViewPathKey;

/* **THE DESKTOP IS A DRAG SOURCE AND A DROP DESTINATION, LIKE A FILE WINDOW IS.** A drag out of it carries the selected
 * paths on the same pasteboard a file window's does, and a drop onto it lands in the desktop's own directory — or in the
 * folder whose icon it was released on — by the same rule (`WSItemDrag`). The gesture is this view's own: a press on an
 * icon that moves is still how an icon is put somewhere else on the desktop. */
@interface WSDesktopView : NSView <NSDraggingSource, WSItemDragSourceReloading, WSItemDragSelectionTaking>
{
	WSItemModel *_model;
	WSMetadataStore *_store;
	NSMutableArray *_positions;	/* NSValue NSPoint, top-left, parallel to the items */
	NSMutableArray *_icons;		/* NSBitmapImageRep, or NSNull until drawn */
	NSMutableArray *_selection;	/* NSNumber indices into the items */

	/* **THE FOLDER IS WATCHED, SO A FILE THAT LANDS HERE IS ON THE DESKTOP.** `libagora-watch`'s stream reports a change
	 * and a timer takes it on the main thread; while a gesture is in flight the reload waits for the hand to let go
	 * (`_pendingReload`), because re-placing every icon mid-drag would move what the person is moving. */
	WSDirectoryWatcher *_watcher;	/* RETAINED */
	BOOL _pendingReload;
	/* **THE ANCHOR IS WHERE A SHIFT-CLICK EXTENDS FROM**, as it is in every grid that has one: the last icon a person
	 * chose on its own. -1 means "nothing to extend from", which a press on the wallpaper sets. */
	NSInteger _anchorIndex;

	BOOL _dragging;
	NSPoint _dragLast;		/* the last pointer position, in top-left coordinates */
	BOOL _moved;

	/* AN OUTGOING DRAG: where the session began, so the icons can be told what the pointer did while the session had it.
	 * An incoming one: which cell is under the pointer and what a drop there would do. */
	/* **THE WORK AREA THE ICONS WERE LAST PLACED IN**, and a timer that watches it: the Dock reserves its strip AFTER
	 * this application has started, and the server's answer changes without anything above the seam being told. */
	NSRect _laidOutWorkArea;
	id _workAreaTimer;		/* NSTimer, RETAINED */

	BOOL _dragSessionBegan;		/* the press became a drag session, which now owns the pointer */
	NSPoint _pressPoint;		/* where it began, in top-left coordinates */
	NSPoint _dragStartWindow;	/* and in the window's, because the session reports its end in screen space */
	NSInteger _dropIndex;
	NSDragOperation _dropOperation;

	BOOL _rubberBanding;
	NSPoint _rubberStart;
	NSRect _rubberRect;

	/* **THE OPERATIONS THE CONTEXT MENU PERFORMS, AND WHO OWNS THEM.** Trash and the operation manager are the
	 * file system's, not a view's, so this view makes its own the way a file window's controller does — with NO undo
	 * manager: a desktop has no Edit menu of its own, so a trashed icon is not undone from here (a file window's
	 * operations keep theirs). */
	WSTrash *_trash;		/* RETAINED */
	WSFileOperations *_fileOperations;	/* RETAINED */

	/* AND THE INLINE RENAME, over the label the same way a file window's grid puts it: the field lands where the name
	 * is drawn, and the directory is read again when the name is committed. */
	NSTextField *_renameField;	/* RETAINED while renaming */
	NSInteger _renameIndex;
	BOOL _renaming;
}

- (instancetype)initWithFrame:(NSRect)frame directory:(NSString *)directory;
- (NSString *)directory;
/* What is on it — the same door the icon view gives a probe, so a test can name an item without reading the screen. */
- (WSItemModel *)model;

/* The icon size this view lays out with, and the door a PREFERENCE comes in through. The size is the store's, so a
 * change is a store change and a re-layout — see the implementation for why the sidecar is saved here too. */
- (NSInteger)iconSize;
- (void)setIconSize:(NSInteger)size;

/* Re-read the directory and re-place the icons. The change stream (libagora-watch) will call this; W1 calls it
 * when the view is made and when a person changes something. */
- (void)reload;
/* The drag destination's answer: the files it moved are gone from here, so read the directory again. */
- (void)reloadAfterChange;

/* **THE CONTEXT MENU, AND WHAT ONE ICON CAN ANSWER.** `-menuForEvent:` is the AppKit's question, asked by `NSView`'s
 * `-rightMouseDown:`; the click names the icon under the pointer and the menu is about that one. Rename, Copy and
 * Move to Trash are implemented here exactly as a file window's grid implements them, so the two surfaces offer the
 * same menu and mean the same things by it. */
- (nullable NSMenu *)menuForEvent:(nullable NSEvent *)theEvent;
- (void)rename:(nullable id)sender;
- (BOOL)commitRenaming;
- (void)cancelRenaming;
- (void)copy:(nullable id)sender;
- (void)cut:(nullable id)sender;
- (void)paste:(nullable id)sender;
- (void)moveToTrash:(nullable id)sender;
/* And the empty desktop's two: make a folder in the desktop's directory, and hold everything on it. */
- (void)newFolder:(nullable id)sender;
- (void)selectAll:(nullable id)sender;
- (void)newFolderWithSelection:(nullable id)sender;
- (nullable NSTextField *)cg_renameField;
- (BOOL)isRenaming;
/* The operations a command performs, so a probe can hand in a trash of its own instead of the account's. Nil is
 * "make my own", which is what the desktop window's view does. */
- (nullable WSFileOperations *)fileOperations;
- (void)setFileOperations:(nullable WSFileOperations *)operations;
/* And the items a drop put here are the ones the hand meant, so they are the ones held. */
- (void)cg_selectPaths:(NSArray *)paths;

/* **EXTRACT ARCHIVE, AS A COMMAND AND AS A QUESTION.** The context menu asks this before it draws the row — the same
 * arrangement the trash's Put Back uses — and the command unpacks every selected `.zip` beside itself into a folder named
 * for it. A double click on an archive takes the same command. */
- (BOOL)cg_selectionCanBeExtracted;
- (void)extractArchive:(nullable id)sender;

/* **THE DRAG, AS A PROBE ASKS FOR IT.** The same two doors the icon view has, for the same reason: a session only
 * begins from a real event, and a test has none. */
- (NSArray *)cg_selectedPaths;
/* The area the grid places into — the work area when this view is the screen, its own bounds otherwise. */
- (NSRect)cg_layoutBounds;
/* **THE DESKTOP'S EAR ON THE FILESYSTEM**, so a probe can turn the main thread's half of it without a run loop. */
- (nullable WSDirectoryWatcher *)cg_watcher;
- (NSDraggingSession *)cg_beginDragWithEvent:(NSEvent *)event;
- (NSDragOperation)cg_updateDropWithInfo:(id <NSDraggingInfo>)info;
- (void)cg_dropSessionDidEnd:(NSPoint)screenPoint operation:(NSDragOperation)operation;

@end

#endif /* WORKSPACE_WSDESKTOPVIEW_H */
