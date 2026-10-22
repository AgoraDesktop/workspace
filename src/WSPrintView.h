/*
 * WSPrintView.h — THE PAGE A FILE MANAGER CAN PRINT: A LISTING.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **A FILE MANAGER PRINTS WHAT IT KNOWS, WHICH IS A LISTING.** Printing a document's contents needs the application
 * that owns the document, and this tree has no Apple Event transport to hand a file to one; what Workspace can print is
 * the thing it shows — a title and one row per item, with the item's kind, size and date. That is the same choice the
 * reference file manager makes for File > Print on a window, and it is the honest one here: a listing of the selection,
 * or of the whole folder when nothing is selected.
 *
 * **THE VIEW IS TALL AND LETS THE PRINT OPERATION CUT IT.** It does not answer `-knowsPageRange:`; the operation
 * paginates it by the ticket's imageable height, which is why a listing of two hundred items needs no arithmetic in
 * this file — only a row height. The title is drawn on the first page only, because the view cannot know where the
 * breaks fall; a running header per page would need `-knowsPageRange:`/`-rectForPage:` and a page count that this
 * tier's file manager does not have to offer.
 *
 * ONE ROW PER PATH, IN THE ORDER GIVEN, with the three facts the list view's columns already show. The width is A4's
 * imageable width, so a default ticket centres it with no clipping.
 */
#ifndef WORKSPACE_WSPRINTVIEW_H
#define WORKSPACE_WSPRINTVIEW_H

#import <AppKit/NSView.h>

@class NSArray;
@class NSString;

/* THE ROW HEIGHT AND THE SHEET'S WIDTH, as numbers a probe can assert rather than re-derive. */
#define WS_PRINT_ROW_HEIGHT 18.0
#define WS_PRINT_VIEW_WIDTH 451.0
#define WS_PRINT_TITLE_HEIGHT 56.0
#define WS_PRINT_BOTTOM_PADDING 24.0

@interface WSPrintView : NSView
{
	NSString *_title;		/* RETAINED */
	NSArray *_rows;			/* RETAINED: NSArray of WSPrintRow */
}

/* ONE PATH OR MANY: the rows are built from the file system in the order given, so a caller's selection order is the
 * page's order. A `title` of nil falls back to the first path's folder, which is what "Print…" on a selection means. */
+ (WSPrintView *)printViewForPaths:(NSArray *)paths title:(NSString *)title;

/* THE HEIGHT THE ROWS NEED, which is what makes the listing paginate: `title band + rows × row height + padding`. */
- (CGFloat)cg_requiredHeight;
- (NSString *)cg_title;
- (NSArray *)cg_rows;
/* AND THE FOUR FIELDS OF ONE ROW, because the row class is this file's: a probe asserting what a page SAYS needs the
 * strings, not the object. An index out of range answers nil. */
- (nullable NSString *)cg_nameAtRow:(NSUInteger)index;
- (nullable NSString *)cg_kindAtRow:(NSUInteger)index;
- (nullable NSString *)cg_sizeAtRow:(NSUInteger)index;
- (nullable NSString *)cg_dateAtRow:(NSUInteger)index;

@end

#endif /* WORKSPACE_WSPRINTVIEW_H */
