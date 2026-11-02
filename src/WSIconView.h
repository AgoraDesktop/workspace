/*
 * WSIconView.h — a file window's icon view: the grid, the keyboard, rename and the drag session.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE GRID IS `WSIconLayout`'S, THE ITEMS ARE `WSItemModel`'S, AND THIS VIEW IS THE PART THAT IS NEITHER.** W2
 * proved the shell; W3 makes the icon mode do what a person expects: a selection that the keyboard can move, a
 * type-select prefix, an inline rename field over the label, and a drag that can leave for another file window and
 * be dropped by another `WSIconView`.
 *
 * **THE ORDER IS LEFT-TO-RIGHT ROWS.** The desktop fills columns right-to-left; a file window reads a row at a
 * time. Both are `WSIconLayout`'s arithmetic, selected by `WSIconOrder`, which is what "the desktop's layout engine
 * reused" means here rather than a second copy of the cell maths.
 *
 * **DRAGGING IS THE TIER'S `NSDraggingSession`.** The source puts the selected paths on `NSDragPboard` as
 * `NSFilenamesPboardType` and begins a session with one item per selected icon; a destination `WSIconView` registers
 * for the type, chooses Move/Copy/Link from the modifier keys and the two volumes, and performs the file operation.
 * The cross-process half is still W7's, so this is a drag between windows of this application.
 *
 * **AN ALIAS IS A SYMBOLIC LINK UNTIL `WSAlias` EXISTS.** The Mac's alias is a bookmark record (`WORKSPACE-PLAN.md`
 * §5.2) and that class is W6's; the Link operation this view performs is `symlink(2)` through `NSFileManager`, and
 * the header says so rather than calling a symlink a Mac alias.
 *
 * **SPRING-LOADED FOLDERS ARE A NOTIFICATION.** Hovering a folder icon for 0.6 s posts
 * `WSIconViewRequestFolderWindowNotification`; the application opens the folder's window, exactly as a desktop
 * folder double-click does. The view does not make windows.
 */
#ifndef WORKSPACE_WSICONVIEW_H
#define WORKSPACE_WSICONVIEW_H

#import <AppKit/NSDragging.h>
#import <AppKit/NSView.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSGeometry.h>
#import <Foundation/NSIndexSet.h>

@class NSTextField;
@class NSTimer;
@class NSMenu;
@class WSItem;
@class WSFileOperations;
@class WSItemModel;

/* A spring-loaded folder asks the application for a window; the path is under this key. */
extern NSString *WSIconViewRequestFolderWindowNotification;
extern NSString *WSIconViewFolderPathKey;

@class WSIconView;

@protocol WSIconViewDelegate <NSObject>
@optional
- (void)iconView:(WSIconView *)view openItem:(WSItem *)item;
- (void)iconViewDidChangeModel:(WSIconView *)view;
/* **AND WHEN A COMMAND THE VIEW PERFORMED IS OVER.** The operation manager a grid is handed belongs to the WINDOW — its
 * progress handler owns a floating window and its undo manager is the window's — so a command that runs an operation
 * from the VIEW has to hand the window the ending, or the progress plate stays on the glass: MEASURED, as a
 * half-transparent rounded panel left in the middle of a file window after New Folder with Selection. A delegate that
 * does not answer still hears `-iconViewDidChangeModel:`, which is the part every caller needs. */
- (void)iconViewDidFinishOperation:(WSIconView *)view;
@end

@interface WSIconView : NSView <NSDraggingSource, NSDraggingDestination>
{
	WSItemModel *_model;			/* RETAINED */
	id <WSIconViewDelegate> _delegate;	/* NOT RETAINED */
	NSMutableArray *_positions;		/* RETAINED: NSValue NSPoint, top-left */
	NSMutableArray *_icons;			/* RETAINED: NSImage or NSNull */
	NSMutableIndexSet *_selection;		/* RETAINED */
	NSInteger _anchorIndex;			/* where a Shift-selection started */
	NSInteger _iconSize;

	/* TYPE-SELECT: the prefix and when the last key arrived. */
	NSMutableString *_typeSelectString;	/* RETAINED */
	NSTimeInterval _typeSelectTime;

	/* THE PRESS AND THE DRAG. */
	NSPoint _pressPoint;
	NSInteger _pressIndex;
	BOOL _pressing;
	BOOL _dragging;

	/* **AND THE BAND A PRESS IN THE EMPTY SPACE BEGINS.** `_bandOrigin` is where the press landed and `_bandRect` is the
	 * normalised rectangle it has been dragged into — in this view's own (flipped) coordinates, which is what the icons'
	 * highlight rects are in. `_bandBase` is the selection as it was when the band began, so a Shift- or Command-drag ADDS
	 * to what was already chosen instead of replacing it. */
	NSPoint _bandOrigin;
	NSRect _bandRect;
	BOOL _banding;
	BOOL _bandAdditive;
	NSIndexSet *_bandBase;			/* RETAINED while a band is in flight */

	/* THE DROP TARGET AND THE SPRING. */
	NSInteger _dropIndex;
	NSDragOperation _dropOperation;
	NSTimer *_springTimer;			/* RETAINED while scheduled */
	NSInteger _springIndex;
	NSInteger _sprungIndex;

	/* THE INLINE RENAME. */
	NSTextField *_renameField;		/* RETAINED while renaming */
	NSInteger _renameIndex;
	BOOL _renaming;

	NSView *_observedClip;			/* NOT RETAINED: the scroll view's clip view */
	WSFileOperations *_fileOperations;	/* RETAINED: the manager the rename goes through */
}
- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model;

- (void)setModel:(WSItemModel *)model;
/* **THE SAME FOLDER, READ AGAIN.** The model was reloaded from the directory; this lays the grid out for its new items
 * and keeps the selection, which `-setModel:` deliberately does not. */
- (void)reloadData;
- (nullable WSItemModel *)model;

- (nullable id <WSIconViewDelegate>)delegate;
- (void)setDelegate:(nullable id <WSIconViewDelegate>)delegate;
- (void)setFileOperations:(nullable WSFileOperations *)operations;

- (NSInteger)itemCount;
- (NSInteger)selectedIndex;
- (NSIndexSet *)selectedIndexes;
- (NSArray *)selectedItems;
- (void)selectIndex:(NSInteger)index;
- (void)selectIndexes:(NSIndexSet *)indexes;

/* The height the grid wants for a given width; the scroll view's document frame is this tall. */
- (CGFloat)contentHeightForWidth:(CGFloat)width;
- (void)layoutItems;

/* INLINE RENAME. `-beginRenamingSelectedItem` refuses unless exactly one item is selected; `-commitRenaming`
 * answers NO when the name is empty, contains `/`, or already exists. */
- (BOOL)beginRenamingSelectedItem;
- (BOOL)commitRenaming;
- (void)cancelRenaming;
- (BOOL)isRenaming;

/* Reload the model and keep the still-present items selected — the destination of a drop and a rename both use it. */
- (void)reloadAfterChange;
/* Select the items at these paths — what a drop of them into this grid means, and the same door a probe uses. */
- (void)cg_selectPaths:(NSArray *)paths;

/* **THE CONTEXT MENU, AND WHAT A SINGLE ITEM CAN ANSWER.** `-menuForEvent:` is the AppKit's question (asked by `NSView`'s
 * `-rightMouseDown:`) and this view answers it for the ONE item under the pointer, narrowing the selection to it first.
 * Rename is the inline field the keyboard already reaches, Move to Trash is W6's, Copy and Cut are the pasteboard, and
 * Paste is what a cut promised — so Get Info is the one row the menu carries and greys, until W8 gives it a window. */
- (nullable NSMenu *)menuForEvent:(nullable NSEvent *)theEvent;
- (void)rename:(nullable id)sender;
- (void)copy:(nullable id)sender;
- (void)cut:(nullable id)sender;
- (void)paste:(nullable id)sender;
- (void)moveToTrash:(nullable id)sender;
/* And the empty grid's two: make a folder in this grid's directory, and hold everything in it. */
- (void)newFolder:(nullable id)sender;
- (void)selectAll:(nullable id)sender;
- (void)newFolderWithSelection:(nullable id)sender;

/* **THE TEST'S SEAMS, PREFIXED AS THE TIER'S PRIVATE DOORS ARE.** `-cg_proposedOperation…` is the policy arithmetic
 * without a live modifier state; `-cg_performDrop…` is the file operation without a fake pasteboard; and
 * `-cg_beginDragWithEvent:` starts the same session a press-and-drag does, so a probe can read the pasteboard and the
 * session it made. */
- (NSArray *)cg_positions;
- (NSRect)cg_highlightRectAtIndex:(NSInteger)index;
- (nullable NSTextField *)cg_renameField;
- (NSDragOperation)cg_proposedOperationForSameVolume:(BOOL)sameVolume modifiers:(NSUInteger)modifiers;
- (BOOL)cg_performDropOfPaths:(NSArray *)paths intoDirectory:(NSString *)directory
		    operation:(NSDragOperation)operation;
- (nullable NSDraggingSession *)cg_beginDragWithEvent:(NSEvent *)event;
- (void)cg_springOpen;

@end

#endif /* WORKSPACE_WSICONVIEW_H */
