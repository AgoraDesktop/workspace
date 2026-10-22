/*
 * WSIconLayout.h — where a desktop's icons go: the grid, and how a drop finds a cell.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * PURE GEOMETRY, AND THAT IS WHY IT IS A CLASS OF ITS OWN: a grid, an arrange order and a collision rule are
 * the arithmetic every icon surface shares — the desktop now, and the icon view of a file window later — and
 * none of it needs a view. Everything here is in TOP-LEFT SCREEN COORDINATES, the same space the metadata
 * store persists and the reference file manager's own `.DS_Store` uses; a view converts to Cocoa only to draw.
 */
#ifndef WORKSPACE_WSICONLAYOUT_H
#define WORKSPACE_WSICONLAYOUT_H

#import <Foundation/NSGeometry.h>
#import <Foundation/NSObject.h>

@class NSArray;

typedef enum {
	WSArrangeNone = 0,	/* free placement: the stored positions win */
	WSArrangeGrid = 1,	/* the grid, in the model's order */
	WSArrangeByName = 2	/* the grid, sorted by name */
} WSArrangeMode;

/* **THE TWO ORDERS THE SAME GRID IS READ IN.** The desktop fills COLUMNS downward and moves RIGHT TO LEFT, which
 * is the Mac's desktop order. A file window's icon view fills ROWS left to right, which is what a person reads. The
 * cell size, the margins, the hit test and the arrange arithmetic are the same; only the index-to-cell walk differs,
 * and keeping both here is what makes W3 "the desktop's layout engine reused" true rather than a second copy. */
typedef enum {
	WSIconOrderRightToLeftColumns = 0,
	WSIconOrderLeftToRightRows = 1
} WSIconOrder;

extern const NSInteger WSIconDefaultSize;
extern const NSInteger WSIconGridMargin;
extern const NSInteger WSIconLabelHeight;
extern const NSInteger WSIconPadding;

@interface WSIconLayout : NSObject

/* Icon plus label plus padding: the cell an icon occupies, and the unit the grid is made of. */
+ (NSSize)cellSizeForIconSize:(NSInteger)iconSize;

/* How many rows fit down one column of a view this tall — never fewer than one, so a tiny window still has a
 * grid rather than a division by zero. */
+ (NSInteger)rowsPerColumnInBounds:(NSRect)bounds iconSize:(NSInteger)iconSize;

/* How many cells fit across the area — the column count an icon view's arrow keys move by. */
+ (NSInteger)columnsInBounds:(NSRect)bounds iconSize:(NSInteger)iconSize order:(WSIconOrder)order;

/* The grid cell for the nth item in a chosen order. The default is the desktop's **TOP-TO-BOTTOM, RIGHT-TO-LEFT**:
 * a column fills downward, then the next column is one cell to the LEFT. The file window asks for
 * `WSIconOrderLeftToRightRows`, which fills a row and then the next row DOWN. */
+ (NSPoint)gridPositionForIndex:(NSInteger)index inBounds:(NSRect)bounds iconSize:(NSInteger)iconSize
			  order:(WSIconOrder)order;
+ (NSPoint)gridPositionForIndex:(NSInteger)index inBounds:(NSRect)bounds iconSize:(NSInteger)iconSize;

/* The free grid cell nearest `desired` — what a drop snaps to. `occupied` is an NSArray of NSValue NSPoints;
 * when every cell is taken the desired position is answered unchanged rather than dropped silently. */
+ (NSPoint)snapPosition:(NSPoint)desired
	       inBounds:(NSRect)bounds
	       iconSize:(NSInteger)iconSize
	       avoiding:(NSArray *)occupied;

/* The order an arrange mode puts names in. Grid and None keep the caller's order; ByName sorts. */
+ (NSArray *)namesByArranging:(NSArray *)names mode:(WSArrangeMode)mode;

/* The icon's own rectangle for a stored top-left position. */
+ (NSRect)iconRectAtPosition:(NSPoint)position iconSize:(NSInteger)iconSize;

/* Which item a point is over, or -1. `positions` is an NSArray of NSValue NSPoints, one per item. */
+ (NSInteger)indexOfPosition:(NSPoint)point among:(NSArray *)positions iconSize:(NSInteger)iconSize;

@end

#endif /* WORKSPACE_WSICONLAYOUT_H */
