/*
 * WSColumnView.m — the browser's columns and the preview that stays at the right.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSColumnView.h"

#import "WSItemIcons.h"
#import "WSItemKind.h"
#import "WSItemModel.h"
#import "WSItemSort.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBrowserCell.h>
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

#define WS_COLUMN_PREVIEW_WIDTH 240.0

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

static NSString *fn_size_string(WSItem *item)
{
	unsigned long long size;

	if ([item isDirectory]) return @"--";
	size = [item size];
	if (size < 1024ULL) return [NSString stringWithFormat:@"%llu bytes", size];
	if (size < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", (double)size / 1024.0];
	if (size < 1024ULL * 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f MB", (double)size / (1024.0 * 1024.0)];
	return [NSString stringWithFormat:@"%.1f GB", (double)size / (1024.0 * 1024.0 * 1024.0)];
}

/* ============================================================================================ *
 * THE PREVIEW — the rightmost column, and the selected item's facts.                           *
 * ============================================================================================ */

@interface WSColumnPreviewView : NSView
{
	WSItem *_item;		/* RETAINED */
}
- (void)setItem:(nullable WSItem *)item;
- (nullable WSItem *)item;
- (NSString *)previewText;
@end

@implementation WSColumnPreviewView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)dealloc
{
	[_item release];
	[super dealloc];
}

- (void)setItem:(WSItem *)item
{
	[item retain];
	[_item release];
	_item = item;
	[self setNeedsDisplay:YES];
}

- (WSItem *)item { return _item; }

- (NSString *)previewText
{
	if (_item == nil) {
		return @"No Selection";
	}
	return [NSString stringWithFormat:@"%@\n%@\n%@\n%@",
		[_item name], [WSItemKind kindForItem:_item], fn_size_string(_item),
		fn_date_string([_item modificationDate])];
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

	if (_item == nil) {
		text = @"No Selection";
		[text drawInRect:NSMakeRect(20.0, 24.0, bounds.size.width - 40.0, 20.0)
			  withAttributes:[NSDictionary dictionaryWithObject:[NSColor darkGrayColor]
								     forKey:NSForegroundColorAttributeName]];
		return;
	}

	icon = [WSItemIcons iconForPath:[_item path] isDirectory:[_item isDirectory] size:64];
	if (icon != nil) {
		[icon drawInRect:NSMakeRect(20.0, 20.0, 64.0, 64.0)];
	}
	nameAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSColor blackColor], NSForegroundColorAttributeName, nil];
	detailAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSColor darkGrayColor], NSForegroundColorAttributeName, nil];
	[[_item name] drawInRect:NSMakeRect(20.0, 96.0, bounds.size.width - 40.0, 20.0)
		  withAttributes:nameAttributes];
	[[WSItemKind kindForItem:_item] drawInRect:NSMakeRect(20.0, 124.0, bounds.size.width - 40.0, 18.0)
				    withAttributes:detailAttributes];
	[fn_size_string(_item) drawInRect:NSMakeRect(20.0, 146.0, bounds.size.width - 40.0, 18.0)
			   withAttributes:detailAttributes];
	[fn_date_string([_item modificationDate]) drawInRect:NSMakeRect(20.0, 168.0, bounds.size.width - 40.0, 18.0)
				      withAttributes:detailAttributes];
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
		_browser = [[NSBrowser alloc] initWithFrame:NSMakeRect(0.0, 0.0,
								      frame.size.width - WS_COLUMN_PREVIEW_WIDTH,
								      frame.size.height)];
		[_browser setDelegate:self];
		[_browser setColumnWidth:220.0];
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
	[_browser loadColumnZero];
}

- (id <WSColumnViewDelegate>)viewDelegate { return _viewDelegate; }
- (void)setViewDelegate:(id <WSColumnViewDelegate>)delegate { _viewDelegate = delegate; }

- (void)reloadData
{
	[_childModels removeAllObjects];
	[_columnCache removeAllObjects];
	[_model reload];
	[_browser loadColumnZero];
	[_preview setItem:nil];
}

/* ---- THE MODEL PER COLUMN -------------------------------------------------------------------- */

- (WSItemModel *)childModelForItem:(WSItem *)item
{
	WSItemModel *child;
	NSString *path;

	if (item == nil || ![item isDirectory]) {
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

	return (column >= 0) ? [self itemAtRow:[_browser selectedRowInColumn:column] column:column] : nil;
}

- (NSArray *)selectedItems
{
	WSItem *item = [self selectedItem];

	return (item != nil) ? [NSArray arrayWithObject:item] : [NSArray array];
}

- (void)updatePreviewForItem:(WSItem *)item
{
	[_preview setItem:item];
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
		[cell setLeaf:![item isDirectory]];
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
	if (column <= 0) {
		return nil;
	}
	parent = [self itemAtRow:[_browser selectedRowInColumn:column - 1] column:column - 1];
	return [parent name];
}

- (void)browserSelectionChanged:(id)sender
{
	(void)sender;
	[self updatePreviewForItem:[self selectedItem]];
}

- (void)openSelectedItem
{
	WSItem *item = [self selectedItem];

	if (item != nil && [_viewDelegate respondsToSelector:@selector(columnView:openItem:)]) {
		[_viewDelegate columnView:self openItem:item];
	}
}

- (NSBrowser *)cg_browser { return _browser; }
- (WSItem *)cg_previewItem { return [_preview item]; }
- (NSString *)cg_previewText { return [_preview previewText]; }

@end
