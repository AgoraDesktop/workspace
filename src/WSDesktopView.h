/*
 * WSDesktopView.h — the desktop's own view: the wallpaper, and the icons on it.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
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

@interface WSDesktopView : NSView
{
	WSItemModel *_model;
	WSMetadataStore *_store;
	NSMutableArray *_positions;	/* NSValue NSPoint, top-left, parallel to the items */
	NSMutableArray *_icons;		/* NSBitmapImageRep, or NSNull until drawn */
	NSMutableArray *_selection;	/* NSNumber indices into the items */

	BOOL _dragging;
	NSPoint _dragLast;		/* the last pointer position, in top-left coordinates */
	BOOL _moved;

	BOOL _rubberBanding;
	NSPoint _rubberStart;
	NSRect _rubberRect;
}

- (instancetype)initWithFrame:(NSRect)frame directory:(NSString *)directory;
- (NSString *)directory;

/* The icon size this view lays out with, and the door a PREFERENCE comes in through. The size is the store's, so a
 * change is a store change and a re-layout — see the implementation for why the sidecar is saved here too. */
- (NSInteger)iconSize;
- (void)setIconSize:(NSInteger)size;

/* Re-read the directory and re-place the icons. The change stream (libagora-watch) will call this; W1 calls it
 * when the view is made and when a person changes something. */
- (void)reload;

@end

#endif /* WORKSPACE_WSDESKTOPVIEW_H */
