/*
 * WSFileIconView.h — the file window's Icon mode, for W2.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **THIS IS THE SHELL'S ICON MODE, NOT W3'S ICON VIEW.** It reads `WSItemModel`, lays the items in a left-to-right
 * grid, draws their icons and labels, selects one and opens it on a double-click. What W3 adds — inline rename,
 * keyboard navigation, type-select, drag and drop, spring-loaded folders, and the desktop's own layout engine — is
 * deliberately absent here so the SHELL can be measured first.
 *
 * The view is FLIPPED: its y grows downward, which is the direction the grid and the hit test are written in, and
 * it is what makes the first row the top one without a second coordinate conversion.
 */
#ifndef WORKSPACE_WSFILEICONVIEW_H
#define WORKSPACE_WSFILEICONVIEW_H

#import <AppKit/NSView.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSGeometry.h>

@class NSMutableArray;
@class WSItem;
@class WSItemModel;
@class WSFileIconView;

@protocol WSFileIconViewDelegate <NSObject>
@optional
- (void)fileIconView:(WSFileIconView *)view openItem:(WSItem *)item;
@end

@interface WSFileIconView : NSView
{
	WSItemModel *_model;		/* RETAINED */
	id <WSFileIconViewDelegate> _delegate;	/* NOT RETAINED */
	NSMutableArray *_positions;	/* RETAINED: NSValue NSPoint, top-left */
	NSMutableArray *_icons;		/* RETAINED: NSImage or NSNull */
	NSInteger _selectedIndex;
	NSInteger _iconSize;
	NSView *_observedClip;		/* NOT RETAINED: the scroll view's clip view */
}
- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model;

- (void)setModel:(WSItemModel *)model;
- (nullable WSItemModel *)model;

- (nullable id <WSFileIconViewDelegate>)delegate;
- (void)setDelegate:(nullable id <WSFileIconViewDelegate>)delegate;

- (NSInteger)itemCount;
- (NSInteger)selectedIndex;
- (void)selectIndex:(NSInteger)index;

/* The height the grid wants for a given width; the scroll view's document frame is this tall. */
- (CGFloat)contentHeightForWidth:(CGFloat)width;

/* Re-run the grid, after a width change or a reload. */
- (void)layoutItems;

@end

#endif /* WORKSPACE_WSFILEICONVIEW_H */
