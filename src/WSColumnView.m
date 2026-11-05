/*
 * WSColumnView.m — the browser's columns and the preview that stays at the right.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSColumnView.h"

#import "WSContextMenu.h"
#import "WSItemDrag.h"
#import "WSFileOperations.h"
#import "WSItemIcons.h"
#import "WSItemKind.h"
#import "WSItemInfo.h"
#import "WSItemModel.h"
#import "WSItemSort.h"
#import "WSQuickLookController.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBrowserCell.h>
#import <AppKit/NSDragging.h>
#import <AppKit/NSPasteboard.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSView.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSIndexSet.h>
#import <Foundation/NSString.h>

#include <time.h>

/* **A PANE ABOUT ONE ITEM, NOT A SECOND COLUMN.** 240 points held a 64-point picture and four short lines with a third of
 * the width empty; 180 still holds the longest line a date can be and gives 60 points back to the columns, which is where
 * a person browsing actually spends the window. */
#define WS_COLUMN_PREVIEW_WIDTH 180.0
/* AND WHAT THE PANE KEEPS CLEAR ON EACH SIDE, so a long name is cut inside the pane instead of spilling across it. */
#define WS_COLUMN_PREVIEW_INSET 10.0

static NSString *fn_date_string(NSDate *date)
{
	time_t seconds;
	struct tm broken;
	char buffer[32];

	if (date == nil) return @"--";
	seconds = (time_t)[date timeIntervalSince1970];
	if (localtime_r(&seconds, &broken) == NULL) return @"--";
	strftime(buffer, sizeof buffer, "%Y-%m-%d %H:%M", &broken);
	return [NSString stringWithUTF8String:buffer];
}

static NSString *fn_size_for_bytes(unsigned long long size)
{
	if (size < 1024ULL) return [NSString stringWithFormat:@"%llu bytes", size];
	if (size < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", (double)size / 1024.0];
	if (size < 1024ULL * 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f MB", (double)size / (1024.0 * 1024.0)];
	return [NSString stringWithFormat:@"%.1f GB", (double)size / (1024.0 * 1024.0 * 1024.0)];
}

/* **A FOLDER'S SIZE IS THE TREE UNDER IT, WHICH THE PANE HAS TO BE TOLD RATHER THAN ASKED FOR.** `WSItem -size` is one
 * `stat`, and for a directory that is an entry block — the pane used to answer "--" because a number it could not stand
 * behind was worse than none. Now the pane shows "Calculating…" and the walk fills it in; only a file's own size is
 * knowable here and now. */
static NSString *fn_size_string(WSItem *item)
{
	if ([item isDirectory]) return @"Calculating…";
	return fn_size_for_bytes([item size]);
}

/* **THE BROWSER'S OWN RIGHT-CLICK, BECAUSE THE EVENT LANDS ON IT AND NOT ON THE WRAPPER.** A column is a table inside an
 * `NSBrowser`, so the menu question is asked of the browser; this subclass answers it with the row and column under the
 * pointer — `-getRow:column:forPoint:` is the browser's own hit test, so no second layout is invented here — and aims the
 * rows at the WINDOW, which owns the commands (`WSContextMenuCommandTarget`). A point below the last row, or in a title
 * strip, is the folder's own menu, exactly as it is on the icon surfaces.
 *
 * **A COLUMN HOLDS SEVERAL ROWS**, so the menu is the same three-way choice a list makes: a row that is one of several
 * held keeps the group and offers the group's commands, a row on its own offers its own, and the space below the rows is
 * the folder's menu. */
@interface WSColumnBrowser : NSBrowser
@end

@implementation WSColumnBrowser

- (NSMenu *)menuForEvent:(NSEvent *)event
{
	NSInteger row = -1;
	NSInteger column = -1;
	id target;

	if (event == nil) {
		return nil;
	}
	target = WSContextMenuCommandTarget(self);
	{
		BOOL inColumn = [self getRow:&row column:&column
				     forPoint:[self convertPoint:[event locationInWindow] fromView:nil]];

		/* **THE COLUMN THE CLICK LANDED IN IS WHAT THE COMMANDS ACT ON**, recorded before any row of the menu exists:
		 * the window owns New Folder and Paste, and it must know that the third column's folder — not the window's — is
		 * where they belong. A point in a gutter or outside the document has no column, and then the window's own folder
		 * is the only answer there is. */
		if (inColumn && column >= 0 && [[self delegate] isKindOfClass:[WSColumnView class]]) {
			[(WSColumnView *)[self delegate] cg_prepareCommandsForColumn:column];
		}
		if (!inColumn || row < 0) {
			return [WSContextMenu menuForBackgroundWithTarget:target];
		}
	}
	/* **A RIGHT-CLICK INSIDE A GROUP KEEPS IT**, the rule the list and the grid follow: narrowing it to the one row under
	 * the pointer would leave the commands a group is for with nothing to act on. */
	if (![[self selectedRowIndexesInColumn:column] containsIndex:(NSUInteger)row]) {
		[self selectRow:row inColumn:column];
	}
	if ([[self selectedRowIndexesInColumn:column] count] > 1) {
		return [WSContextMenu menuForMultipleItemsWithTarget:target];
	}
	return [WSContextMenu menuForSingleItemWithTarget:target];
}

@end

/* ============================================================================================ *
 * THE PREVIEW — the rightmost column, and the selected item's facts.                           *
 * ============================================================================================ */

@interface WSColumnPreviewView : NSView
{
	WSItem *_item;		/* RETAINED */
	NSString *_sizeText;	/* RETAINED: what the size line says, once it is known */
}
- (void)setItem:(nullable WSItem *)item;
- (nullable WSItem *)item;
- (void)cg_setSizeText:(nullable NSString *)text;
- (NSString *)previewText;
@end

@implementation WSColumnPreviewView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)dealloc
{
	[_item release];
	[_sizeText release];
	[super dealloc];
}

- (void)setItem:(WSItem *)item
{
	[item retain];
	[_item release];
	_item = item;
	[_sizeText release];
	_sizeText = nil;
	[self setNeedsDisplay:YES];
}

- (void)cg_setSizeText:(NSString *)text
{
	[text retain];
	[_sizeText release];
	_sizeText = text;
	[self setNeedsDisplay:YES];
	/* **AND THE WINDOW IS MARKED STALE WITH IT.** A subview's dirty rect is drawn by the update pass, but the pass it
	 * belongs to is the window's: MEASURED, a pane that marked only itself stayed on "Calculating…" for ever while the
	 * answer had arrived and been stored — the text was right and nothing ever painted it. The tracking loop's own
	 * repaint writes the same pair for the same reason. */
	[[self window] setNeedsDisplay:YES];
}

- (WSItem *)item { return _item; }

/* **THE PANE'S FOUR LINES, IN ONE PLACE, BECAUSE TWO THINGS READ THEM.** The pane DRAWS these and a probe ASKS for
 * them (`-previewText`), and MEASURED they disagreed: a measured size was wired into the text door while the drawing
 * called `fn_size_string` for itself, so the pane sat on "Calculating…" while the answer had arrived, been stored and
 * been correct. One list, two readers. */
- (NSArray *)cg_lines
{
	if (_item == nil) {
		return [NSArray arrayWithObject:@"No Selection"];
	}
	return [NSArray arrayWithObjects:
		[_item name],
		[WSItemKind kindForItem:_item],
		(_sizeText != nil) ? _sizeText : fn_size_string(_item),
		fn_date_string([_item modificationDate]),
		nil];
}

- (NSString *)previewText
{
	return [[self cg_lines] componentsJoinedByString:@"\n"];
}

/* **A LINE CENTRED IN THE PANE, MEASURED AND DRAWN WHERE ITS OWN WIDTH PUTS IT.** The tier's `-drawInRect:` lays a line
 * out from the rect's own origin, so a rect that is exactly as wide as the line and centred draws the line centred — and
 * a point of slack on each side keeps a glyph's overhang from being clipped by the rect that measured it. */
static void fn_draw_centred(NSString *text, CGFloat y, CGFloat height, CGFloat paneWidth, NSDictionary *attributes)
{
	NSSize size;

	if (text == nil || [text length] == 0) {
		return;
	}
	CGFloat room = paneWidth - 2.0 * WS_COLUMN_PREVIEW_INSET;

	size = [text sizeWithAttributes:attributes];
	if (size.width <= 0.0) {
		return;
	}
	/* **A LINE WIDER THAN THE PANE IS CUT INSIDE IT, NOT DRAWN ACROSS IT.** The pane is narrower now, and a file name can
	 * be longer than any pane; a rect wider than the pane would run under the browser's own edge, so the rect is the room
	 * the pane has and the centring is the pair of insets that room leaves. */
	if (size.width > room) {
		[text drawInRect:NSMakeRect(WS_COLUMN_PREVIEW_INSET, y, room, height) withAttributes:attributes];
		return;
	}
	[text drawInRect:NSMakeRect((paneWidth - size.width) / 2.0 - 1.0, y, size.width + 2.0, height)
	  withAttributes:attributes];
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	NSDictionary *nameAttributes;
	NSDictionary *detailAttributes;
	NSImage *icon;
	NSString *text;

	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.97 alpha:1.0] setFill];
	[[NSBezierPath bezierPathWithRect:bounds] fill];
	[[NSColor colorWithCalibratedWhite:0.78 alpha:1.0] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, 1.0, bounds.size.height)] fill];

	/* **THE PANE'S CONTENTS ARE CENTRED, BECAUSE A PANE IS A COLUMN OF ONE THING.** The picture and the four facts sat
	 * against a twenty-point left margin, which read as the top of a list that had been cut off rather than as a panel
	 * about one item; a person looking at the rightmost column is looking at ONE thing, and the middle of the pane is
	 * where one thing belongs. */
	if (_item == nil) {
		text = @"No Selection";
		fn_draw_centred(text, 24.0, 20.0, bounds.size.width,
				[NSDictionary dictionaryWithObject:[NSColor darkGrayColor]
							   forKey:NSForegroundColorAttributeName]);
		return;
	}

	icon = [WSItemIcons iconForPath:[_item path] isDirectory:[_item isDirectory] size:64];
	if (icon != nil) {
		[icon drawInRect:NSMakeRect((bounds.size.width - 64.0) / 2.0, 20.0, 64.0, 64.0)];
	}
	nameAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSColor blackColor], NSForegroundColorAttributeName, nil];
	detailAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSColor darkGrayColor], NSForegroundColorAttributeName, nil];
	{
		NSArray *lines = [self cg_lines];

		if ([lines count] >= 4) {
			fn_draw_centred([lines objectAtIndex:0], 96.0, 20.0, bounds.size.width, nameAttributes);
			fn_draw_centred([lines objectAtIndex:1], 124.0, 18.0, bounds.size.width, detailAttributes);
			fn_draw_centred([lines objectAtIndex:2], 146.0, 18.0, bounds.size.width, detailAttributes);
			fn_draw_centred([lines objectAtIndex:3], 168.0, 18.0, bounds.size.width, detailAttributes);
		}
	}
}

@end

/* ============================================================================================ *
 * THE COLUMN VIEW.                                                                              *
 * ============================================================================================ */

@implementation WSColumnView

- (instancetype)initWithFrame:(NSRect)frame model:(WSItemModel *)model
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_model = [model retain];
		_childModels = [[NSMutableDictionary alloc] init];
		_columnCache = [[NSMutableDictionary alloc] init];
		_browser = [[WSColumnBrowser alloc] initWithFrame:NSMakeRect(0.0, 0.0,
								      frame.size.width - WS_COLUMN_PREVIEW_WIDTH,
								      frame.size.height)];
		[_browser setDelegate:self];
		[_browser setColumnWidth:220.0];
		/* **THE COLUMN WIDTHS ARE REMEMBERED, AND THE BROWSER ALREADY KNOWS HOW.** `-setColumnsAutosaveName:` reads the
		 * widths a person dragged out of the standard defaults and `-setWidth:ofColumn:` writes them back on every change;
		 * without a name none of it happens, which is why a column dragged wider came back at 220 in the next window. The
		 * name is the APPLICATION's rather than the window's: one person browses one way, and Apple's autosave name is
		 * per name for the same reason.
		 *
		 * **AND IT GOES AFTER THE DEFAULT WIDTH, NOT BEFORE.** `-setColumnWidth:` sets the width new columns get AND
		 * rewrites every column it already has, so naming the autosave first loaded the remembered widths and then had
		 * them replaced by 220 — MEASURED, the next window ignored the drag it had just saved. */
		[_browser setColumnsAutosaveName:@"WorkspaceFileWindow"];
		[_browser setMinColumnWidth:120.0];
		[_browser setMaxVisibleColumns:3];
		[_browser setSeparatesColumns:YES];
		/* **EACH SEPARATOR IS A HANDLE, AND EACH COLUMN SCROLLS ITSELF.** The browser implements the per-column
		 * scroll views; the resizing type is the caller's choice, and this is the caller that wants it. */
		[_browser setColumnResizingType:NSBrowserUserColumnResizing];
		[_browser setHasHorizontalScroller:YES];
		[_browser setTarget:self];
		[_browser setAction:@selector(browserSelectionChanged:)];
		[_browser setDoubleAction:@selector(openSelectedItem)];
		/* **A COLUMN HOLDS SEVERAL ROWS AT ONCE**, which is what Shift- and Control-click in a browser mean: a range or a
		 * set of files in the same folder, so Move to Trash, Copy or a drag can take them all. The browser's own rule still
		 * picks the column's first selected row to open the column to the right, so the browse path stays predictable. */
		[_browser setAllowsMultipleSelection:YES];
		/* **AND THE COLUMNS ARE A DRAG SOURCE AND A DROP DESTINATION**, which the browser forwards to this delegate: the
		 * type is registered on the BROWSER and it applies it to each column's table as columns are made, and the masks
		 * say what a drag out of here offers. */
		[_browser registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
		[_browser setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
		[_browser setDraggingSourceOperationMask:NSDragOperationEvery forLocal:NO];
		_preview = [[WSColumnPreviewView alloc] initWithFrame:
			NSMakeRect(frame.size.width - WS_COLUMN_PREVIEW_WIDTH, 0.0,
				   WS_COLUMN_PREVIEW_WIDTH, frame.size.height)];
		[self addSubview:_browser];
		[self addSubview:_preview];
		[_browser loadColumnZero];
	}
	return self;
}

- (void)dealloc
{
	[_model release];
	[_childModels release];
	[_columnCache release];
	[_commandDirectory release];
	[_previewPath release];
	[_browser release];
	[_preview release];
	[super dealloc];
}

- (BOOL)isFlipped { return NO; }

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self layoutParts];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
	(void)oldSize;
	[self layoutParts];
}

- (void)layoutParts
{
	NSRect bounds = [self bounds];

	[_browser setFrame:NSMakeRect(0.0, 0.0, bounds.size.width - WS_COLUMN_PREVIEW_WIDTH,
				      bounds.size.height)];
	[_preview setFrame:NSMakeRect(bounds.size.width - WS_COLUMN_PREVIEW_WIDTH, 0.0,
				      WS_COLUMN_PREVIEW_WIDTH, bounds.size.height)];
}

- (WSItemModel *)model { return _model; }

- (void)setModel:(WSItemModel *)model
{
	[model retain];
	[_model release];
	_model = model;
	[_childModels removeAllObjects];
	[_columnCache removeAllObjects];
	[_preview setItem:nil];
	[_previewPath release];
	_previewPath = nil;
	[_browser loadColumnZero];
}

- (id <WSColumnViewDelegate>)viewDelegate { return _viewDelegate; }
- (void)setViewDelegate:(id <WSColumnViewDelegate>)delegate { _viewDelegate = delegate; }

- (WSFileOperations *)fileOperations { return _fileOperations; }
- (void)setFileOperations:(WSFileOperations *)operations { _fileOperations = operations; }

/* **A RELOAD RE-READS THE FOLDER; IT DOES NOT CLOSE THE COLUMNS.** `-loadColumnZero` forgets every selection, which is
 * what a new directory wants and what a trashed file must NOT get: a person who moves the selected file to the Trash is
 * looking at the same folder they were, and having the browser collapse to column zero loses their place. So the chain
 * of selected items is remembered BY PATH — the rows move when a name leaves the sort — and selected again column by
 * column, which re-opens the columns the way a click does.
 *
 * **THE LAST ITEM IN THE CHAIN IS THE ONE THAT MAY BE GONE.** When it is (that is the Trash, a delete, a move out), the
 * column that held it stays open with nothing selected and the preview empties; when it is still there, it is selected
 * again and nothing about the view changed. A chain that breaks earlier stops there: an ancestor that no longer exists
 * is a stale place, and the columns beyond it have nothing to show. */
/* **WHICH FOLDER A COLUMN LISTS.** Column zero lists the model's own folder; a later column lists the children of the
 * item selected in the column to its left, which is where that column's rows came from. */
- (NSString *)cg_directoryForColumn:(NSInteger)column
{
	WSItem *parent;

	if (column <= 0) {
		return [_model directory];
	}
	parent = [self itemAtRow:[_browser selectedRowInColumn:column - 1] column:column - 1];
	return ([parent path] != nil) ? [parent path] : [_model directory];
}

- (NSArray *)cg_visibleDirectories
{
	NSMutableArray *paths = [NSMutableArray array];
	NSInteger count = [_browser cg_activeColumnCount];
	NSInteger selected = [_browser selectedColumn];
	NSInteger i;

	/* **THE COLUMN A CLICK JUST OPENED COUNTS, EVEN BEFORE THE BROWSER HAS GROWN IT.** The browser makes the column
	 * beside a selection after its delegate answers, so a set computed in the delegate's own turn would still be the
	 * old one; the selected column is the newest folder on the glass and is included by its index. */
	if (selected + 2 > count) {
		count = selected + 2;
	}
	if (count > [_browser cg_columnCount]) {
		count = [_browser cg_columnCount];	/* the pool's own bound, which a stale index cannot ask past */
	}
	for (i = 0; i < count; i++) {
		NSString *directory = [self cg_directoryForColumn:i];

		if (directory != nil && ![paths containsObject:directory]) {
			[paths addObject:directory];
		}
	}
	return paths;
}

- (void)cg_prepareCommandsForColumn:(NSInteger)column
{
	NSString *directory = [[self cg_directoryForColumn:column] copy];

	[_commandDirectory release];
	_commandDirectory = directory;
}

- (NSString *)cg_commandDirectory
{
	return (_commandDirectory != nil) ? _commandDirectory : [_model directory];
}

- (void)reloadData
{
	NSArray *chain = [self cg_selectedPathChain];
	NSUInteger count = [chain count];
	NSUInteger restored;

	[_childModels removeAllObjects];
	[_columnCache removeAllObjects];
	[_model reload];
	[_browser loadColumnZero];
	restored = [self cg_restorePathChain:chain];
	if (restored == 0 || restored < count) {
		[self updatePreviewForItem:nil];
	}
}

/* The items selected in columns zero through the selected column, as paths, leaf last. */
- (NSArray *)cg_selectedPathChain
{
	NSMutableArray *chain = [[NSMutableArray alloc] init];
	NSInteger selected = [_browser selectedColumn];
	NSInteger column;

	for (column = 0; column <= selected; column++) {
		WSItem *item = [self itemAtRow:[_browser selectedRowInColumn:column] column:column];

		if (item == nil) {
			break;
		}
		[chain addObject:[item path]];
	}
	return [chain autorelease];
}

- (NSInteger)cg_rowForPath:(NSString *)path inColumn:(NSInteger)column
{
	NSArray *items = [self itemsForColumn:column];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		if ([[[items objectAtIndex:i] path] isEqual:path]) {
			return (NSInteger)i;
		}
	}
	return -1;
}

/* Selecting each column in turn is what loads the next one; the answer is how many of the chain survived. */
- (NSUInteger)cg_restorePathChain:(NSArray *)chain
{
	NSUInteger i;

	for (i = 0; i < [chain count]; i++) {
		NSString *path = [chain objectAtIndex:i];
		NSInteger row = [self cg_rowForPath:path inColumn:(NSInteger)i];

		if (row < 0) {
			return i;
		}
		[_browser selectRow:row inColumn:(NSInteger)i];
	}
	return i;
}

/* ---- THE MODEL PER COLUMN -------------------------------------------------------------------- */

/* **A PACKAGE OPENS NO COLUMN.** Selecting an application bundle is selecting a thing, not a place: it previews and
 * can be opened, and the browser grows no column of its `Contents`. */
- (WSItemModel *)childModelForItem:(WSItem *)item
{
	WSItemModel *child;
	NSString *path;

	if (item == nil || ![item isBrowsable]) {
		return nil;
	}
	path = [item path];
	child = [_childModels objectForKey:path];
	if (child == nil) {
		child = [[WSItemModel alloc] initWithDirectory:path];
		[_childModels setObject:child forKey:path];
		[child release];
	}
	return child;
}

- (NSArray *)itemsForColumn:(NSInteger)column
{
	NSNumber *key = [NSNumber numberWithInteger:column];
	NSArray *items = [_columnCache objectForKey:key];
	WSItem *parent;
	WSItemModel *model;

	if (items != nil) {
		return items;
	}
	if (column == 0) {
		model = _model;
	} else {
		parent = [self itemAtRow:[_browser selectedRowInColumn:column - 1] column:column - 1];
		model = [self childModelForItem:parent];
	}
	items = (model != nil)
		? [WSItemSort sortedItems:[model items] key:WSItemSortName ascending:YES]
		: [NSArray array];
	[_columnCache setObject:items forKey:key];
	return items;
}

- (WSItem *)itemAtRow:(NSInteger)row column:(NSInteger)column
{
	NSArray *items;

	if (row < 0) {
		return nil;
	}
	items = [self itemsForColumn:column];
	return (row < (NSInteger)[items count]) ? [items objectAtIndex:(NSUInteger)row] : nil;
}

- (WSItem *)selectedItem
{
	NSInteger column = [_browser selectedColumn];
	NSIndexSet *rows;

	if (column < 0) {
		return nil;
	}
	rows = [_browser selectedRowIndexesInColumn:column];
	return ([rows count] > 0) ? [self itemAtRow:(NSInteger)[rows firstIndex] column:column] : nil;
}

/* **THE SELECTION IS THE COLUMN'S ROWS, PLURAL.** A browser keeps one selection per column and a column can hold
 * several rows once Shift- or Control-click has added them; the preview describes the first, which is the row the
 * browser itself treats as the column's selection. */
- (NSArray *)selectedItems
{
	NSInteger column = [_browser selectedColumn];
	NSIndexSet *rows;
	NSMutableArray *items = [NSMutableArray array];
	NSUInteger row;

	if (column < 0) {
		return items;
	}
	rows = [_browser selectedRowIndexesInColumn:column];
	if ([rows count] == 0) {
		return items;
	}
	for (row = [rows firstIndex]; row != NSNotFound; row = [rows indexGreaterThanIndex:row]) {
		WSItem *item = [self itemAtRow:(NSInteger)row column:column];

		if (item != nil) {
			[items addObject:item];
		}
	}
	return items;
}

/* **A FOLDER'S SIZE IN THE PANE IS A WALK, SO IT SAYS "Calculating…" AND ARRIVES LATER.** MEASURED: 12.9 ms over 3,801
 * entries and 7.7 s for `/usr`, which is not a wait to spend on a click that already felt instantaneous. The walk keeps
 * this view alive until it answers (`+cg_measurePathsInBackground:target:selector:`), and the answer names the path it is
 * about — a row the person has since left is dropped rather than drawn under the wrong name. */
- (void)updatePreviewForItem:(WSItem *)item
{
	[_preview setItem:item];
	[_previewPath release];
	_previewPath = [[item path] copy];
	if (item != nil && [item isDirectory]) {
		[WSItemInfo cg_measurePathsInBackground:[NSArray arrayWithObject:[item path]]
						 target:self
					       selector:@selector(cg_measuredPreview:)];
	}
	[self fn_visibleDirectoriesMayHaveChanged];
}

- (void)cg_measuredPreview:(NSArray *)result
{
	NSArray *answered = [result lastObject];

	if (_previewPath == nil || ![answered isEqualToArray:[NSArray arrayWithObject:_previewPath]]) {
		return;
	}
	[self cg_setPreviewMeasuredBytes:[[result objectAtIndex:0] unsignedLongLongValue]];
}

- (void)cg_setPreviewMeasuredBytes:(unsigned long long)bytes
{
	if (_previewPath == nil) {
		return;
	}
	[_preview cg_setSizeText:fn_size_for_bytes(bytes)];
}

/* ---- THE BROWSER'S DELEGATE ------------------------------------------------------------------ */

- (NSInteger)browser:(NSBrowser *)sender numberOfRowsInColumn:(NSInteger)column
{
	(void)sender;
	return (NSInteger)[[self itemsForColumn:column] count];
}

- (void)browser:(NSBrowser *)sender willDisplayCell:(id)cell atRow:(NSInteger)row column:(NSInteger)column
{
	WSItem *item = [self itemAtRow:row column:column];

	(void)sender;
	if (item == nil) {
		return;
	}
	[cell setStringValue:[item name]];
	[cell setImage:[WSItemIcons iconForPath:[item path] isDirectory:[item isDirectory] size:16]];
	if ([cell respondsToSelector:@selector(setLeaf:)]) {
		[cell setLeaf:![item isBrowsable]];
		[cell setLoaded:YES];
	}
}

- (BOOL)browser:(NSBrowser *)sender selectRow:(NSInteger)row inColumn:(NSInteger)column
{
	WSItem *item = [self itemAtRow:row column:column];

	(void)sender;
	/* A NEW SELECTION INVALIDATES EVERY COLUMN TO ITS RIGHT, and the preview follows the row even when the browser
	 * is driven programmatically (the control's action is suppressed for a programmatic selection). */
	{
		NSMutableArray *stale = [[NSMutableArray alloc] init];
		NSUInteger i;

		for (i = 0; i < [[_columnCache allKeys] count]; i++) {
			NSNumber *key = [[_columnCache allKeys] objectAtIndex:i];

			if ([key integerValue] > column) {
				[stale addObject:key];
			}
		}
		[_columnCache removeObjectsForKeys:stale];
		[stale release];
	}
	[self updatePreviewForItem:item];
	return YES;
}

- (NSString *)browser:(NSBrowser *)sender titleOfColumn:(NSInteger)column
{
	WSItem *parent;

	(void)sender;
	/* **THE FIRST COLUMN IS NAMED FOR THE FOLDER THE WINDOW SHOWS**, because that is what it lists: the rest are named
	 * for the item selected in the column to their left, and column zero has no column to its left. Answering nil left
	 * the leftmost header blank — "the first column is not showing any header text" — while every column after it had a
	 * title. */
	if (column <= 0) {
		return [[_model directory] lastPathComponent];
	}
	parent = [self itemAtRow:[_browser selectedRowInColumn:column - 1] column:column - 1];
	return [parent name];
}

- (void)browserSelectionChanged:(id)sender
{
	(void)sender;
	[self updatePreviewForItem:[self selectedItem]];
}

/* **A SELECTION IS A NEW COLUMN BESIDE IT, SO THE FOLDERS ON THE GLASS JUST CHANGED.** The window watches what the view
 * shows — the same rule that makes an expanded list row a watch — and it cannot be told inside the selection itself,
 * because the browser grows the column AFTER its delegate answers. So the announcement waits one turn of the run loop,
 * by which time the browser has settled; `-setPaths:` does nothing when the set is the same, so a click that opens
 * nothing costs one comparison. MEASURED as "column view is slow to notice changes in the filesystem": only the window's
 * own folder was watched, so a change in an open column arrived when something else happened to refresh. */
- (void)fn_announceVisibleDirectories
{
	if ([_viewDelegate respondsToSelector:@selector(columnViewDidChangeVisibleDirectories:)]) {
		[_viewDelegate columnViewDidChangeVisibleDirectories:self];
	}
}

- (void)fn_visibleDirectoriesMayHaveChanged
{
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fn_announceVisibleDirectories)
						   object:nil];
	[self performSelector:@selector(fn_announceVisibleDirectories) withObject:nil afterDelay:0.0];
}

/* ---- THE DRAG, OUT AND IN --------------------------------------------------------------------- */

/* **A COLUMN'S DRAG IS THE BROWSER'S, AND THE BROWSER ASKS ITS DELEGATE.** The three answers below are Apple's own deal
 * for a browser: the rows a drag carries, the drop a pointer is proposing, and the drop that ends one. The item under a
 * row and column is `-itemAtRow:column:`, so nothing here re-derives the layout. */

- (NSArray *)cg_pathsForRows:(NSIndexSet *)rows column:(NSInteger)column
{
	NSMutableArray *paths = [[NSMutableArray alloc] init];
	NSUInteger row;

	for (row = [rows firstIndex]; row != NSNotFound; row = [rows indexGreaterThanIndex:row]) {
		WSItem *item = [self itemAtRow:(NSInteger)row column:column];

		if (item != nil) {
			[paths addObject:[item path]];
		}
	}
	return [paths autorelease];
}

- (BOOL)browser:(NSBrowser *)browser writeRowsWithIndexes:(NSIndexSet *)rowIndexes inColumn:(NSInteger)column
   toPasteboard:(NSPasteboard *)pasteboard
{
	NSArray *paths = [self cg_pathsForRows:rowIndexes column:column];

	(void)browser;
	if ([paths count] == 0) {
		return NO;
	}
	[pasteboard declareTypes:[NSArray arrayWithObject:NSFilenamesPboardType] owner:nil];
	[pasteboard setPropertyList:paths forType:NSFilenamesPboardType];
	return YES;
}

/* **WHERE A DROP IN A COLUMN LANDS.** A folder's own row is a place a file can go; any other row means the folder that
 * column is showing, which is the parent of the rows in it — the same rule the tree and the grid follow with a row and
 * with a cell. */
- (NSString *)cg_dropDirectoryForRow:(NSInteger)row column:(NSInteger)column browser:(NSBrowser *)browser
{
	WSItem *item = [self itemAtRow:row column:column];
	WSItem *parent;

	if (item != nil) {
		if ([item isDirectory]) {
			return [item path];
		}
		parent = (column > 0)
			? [self itemAtRow:[browser selectedRowInColumn:column - 1] column:column - 1]
			: nil;
		return ([parent isDirectory]) ? [parent path] : [_model directory];
	}
	return ([self cg_directoryForColumn:column browser:browser]);
}

/* The folder a column is showing, which is the model's directory for the first column and the selected parent beyond it. */
- (NSString *)cg_directoryForColumn:(NSInteger)column browser:(NSBrowser *)browser
{
	WSItem *parent;

	if (column <= 0) {
		return [_model directory];
	}
	parent = [self itemAtRow:[browser selectedRowInColumn:column - 1] column:column - 1];
	return ([parent isDirectory]) ? [parent path] : [_model directory];
}

- (NSDragOperation)browser:(NSBrowser *)browser validateDrop:(id <NSDraggingInfo>)info
	       proposedRow:(NSInteger *)row column:(NSInteger *)column
    proposedDropOperation:(NSBrowserDropOperation *)dropOperation
{
	NSArray *paths = WSItemDragPaths(info);
	NSString *target;
	NSDragOperation operation;

	(void)dropOperation;
	if ([paths count] == 0 || row == NULL || column == NULL) {
		return NSDragOperationNone;
	}
	target = [self cg_dropDirectoryForRow:*row column:*column browser:browser];
	if (target == nil) {
		return NSDragOperationNone;
	}
	operation = WSItemDragOperation(paths, target, [info draggingSourceOperationMask], [NSEvent modifierFlags]);
	/* **A FOLDER ROW SAYS "IN HERE".** The table proposes an insertion line; a drop onto a folder is a drop INTO it, and
	 * that is the answer the destination above just gave. */
	if (operation != NSDragOperationNone && *row >= 0
	    && [[self itemAtRow:*row column:*column] isDirectory]) {
		if (dropOperation != NULL) {
			*dropOperation = NSBrowserDropOn;
		}
	}
	return operation;
}

- (BOOL)browser:(NSBrowser *)browser acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row
	 column:(NSInteger)column dropOperation:(NSBrowserDropOperation)dropOperation
{
	NSArray *paths = WSItemDragPaths(info);
	NSString *target = [self cg_dropDirectoryForRow:row column:column browser:browser];
	NSDragOperation operation;
	BOOL performed;

	(void)dropOperation;
	if (target == nil) {
		return NO;
	}
	operation = WSItemDragOperation(paths, target, [info draggingSourceOperationMask], [NSEvent modifierFlags]);
	performed = WSItemDragPerformWithOperations(paths, target, operation, _fileOperations);
	if (performed) {
		[self reloadData];
		if ([_viewDelegate respondsToSelector:@selector(columnViewDidChangeModel:)]) {
			[_viewDelegate columnViewDidChangeModel:self];
		}
		if ([[info draggingSource] respondsToSelector:@selector(reloadAfterChange)]) {
			[(id <WSItemDragSourceReloading>)[info draggingSource] reloadAfterChange];
		}
	}
	return performed;
}

- (void)openSelectedItem
{
	WSItem *item = [self selectedItem];

	if (item != nil && [_viewDelegate respondsToSelector:@selector(columnView:openItem:)]) {
		[_viewDelegate columnView:self openItem:item];
	}
}

+ (CGFloat)cg_previewWidth
{
	return WS_COLUMN_PREVIEW_WIDTH;
}

- (NSBrowser *)cg_browser { return _browser; }
- (WSItem *)cg_previewItem { return [_preview item]; }

- (NSString *)cg_previewSizeText
{
	NSArray *lines = [[_preview previewText] componentsSeparatedByString:@"\n"];

	return ([lines count] > 2) ? [lines objectAtIndex:2] : nil;
}
- (NSString *)cg_previewText { return [_preview previewText]; }


/* **SPACE IS THE GLANCE HERE TOO.** The icon and list views answer it themselves; a column view is an `NSBrowser` subclass,
 * which would otherwise hand the key to the browser's own type-select — so it answers the same two keys the same way and
 * forwards everything else. */
- (void)keyDown:(NSEvent *)event
{
	NSString *characters = [event characters];
	NSUInteger flags = [event modifierFlags];

	if ([characters length] > 0) {
		unichar character = [characters characterAtIndex:0];

		if (character == ' ' && (flags & (NSCommandKeyMask | NSControlKeyMask)) == 0) {
			[NSApp sendAction:@selector(quickLook:) to:nil from:self];
			return;
		}
		if (character == 0x1b && [[WSQuickLookController sharedController] isShowing]) {
			[[WSQuickLookController sharedController] hide];
			return;
		}
	}
	[super keyDown:event];
}

@end
