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

@class NSMutableArray;
@class NSString;
@class WSItemModel;
@class WSMetadataStore;

@protocol WSItemDragSourceReloading;

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
@interface WSDesktopView : NSView <NSDraggingSource, WSItemDragSourceReloading>
{
	WSItemModel *_model;
	WSMetadataStore *_store;
	NSMutableArray *_positions;	/* NSValue NSPoint, top-left, parallel to the items */
	NSMutableArray *_icons;		/* NSBitmapImageRep, or NSNull until drawn */
	NSMutableArray *_selection;	/* NSNumber indices into the items */

	BOOL _dragging;
	NSPoint _dragLast;		/* the last pointer position, in top-left coordinates */
	BOOL _moved;

	/* AN OUTGOING DRAG: where the session began, so the icons can be told what the pointer did while the session had it.
	 * An incoming one: which cell is under the pointer and what a drop there would do. */
	BOOL _dragSessionBegan;		/* the press became a drag session, which now owns the pointer */
	NSPoint _pressPoint;		/* where it began, in top-left coordinates */
	NSPoint _dragStartWindow;	/* and in the window's, because the session reports its end in screen space */
	NSInteger _dropIndex;
	NSDragOperation _dropOperation;

	BOOL _rubberBanding;
	NSPoint _rubberStart;
	NSRect _rubberRect;
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

/* **THE DRAG, AS A PROBE ASKS FOR IT.** The same two doors the icon view has, for the same reason: a session only
 * begins from a real event, and a test has none. */
- (NSArray *)cg_selectedPaths;
- (NSDraggingSession *)cg_beginDragWithEvent:(NSEvent *)event;
- (NSDragOperation)cg_updateDropWithInfo:(id <NSDraggingInfo>)info;
- (void)cg_dropSessionDidEnd:(NSPoint)screenPoint operation:(NSDragOperation)operation;

@end

#endif /* WORKSPACE_WSDESKTOPVIEW_H */
